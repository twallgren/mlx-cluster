#!/bin/zsh
#
# configure_node.zsh — install a matching MLX/MLX-LM environment on ONE node
#
# Runs locally on a cluster node (ai-1/ai-2/ai-3), invoked directly or via
# main.zsh over SSH. Idempotent: safe to re-run, skips work already done.
#
# Installs Homebrew (if missing), a pinned Python version, and a venv at a
# fixed path with mlx + mlx-lm — the guide requires the same Python/MLX/
# MLX-LM versions and the same Python executable path on every node. Also
# disables sleep so a MacBook Pro node keeps running lid-closed with no
# external display attached (needs sudo — run this over `ssh -t`).
#
# Usage:
#   configure_node.zsh [options]
#
# See --help for full option list.

set -o pipefail
emulate -L zsh

# ---------- defaults ----------
PYTHON_VERSION="3.12"
VENV_PATH="$HOME/mlx-env"
MLX_LM_VERSION=""   # empty = latest release from PyPI
MLX_LM_GIT=""       # "URL#branch" -> editable install instead of PyPI
MLX_LM_SRC="$HOME/mlx-lm-src"
FORCE_PYPI=0
SKIP_MLX_LM=0
DISABLE_SLEEP=1
DRY_RUN=0

usage() {
  cat <<'EOF'
configure_node.zsh [options]

Options:
  --python-version VER                Homebrew python formula version, e.g. 3.12 (default:
                                      3.12) Must match across every node in the cluster.
  --venv-path PATH                    Path to the venv (default: ~/mlx-env) Must be the SAME
                                      path on every node.
  --mlx-lm-version VER                Pin mlx-lm to an exact PyPI version (default: latest
                                      release). Note that the newest *tagged* release can be
                                      months behind the repo's main branch, so a bug fixed
                                      upstream may not be in any version you can install
                                      this way — check the commit log before assuming you
                                      have the fix.
  --mlx-lm-git URL[#REF]              Install mlx-lm as an EDITABLE git checkout instead of
                                      from PyPI, cloned to --mlx-lm-src. Use this when you
                                      carry local patches: they live as commits on your
                                      branch, so upgrading is a merge rather than a silent
                                      revert. Example: --mlx-lm-git
                                      https://github.com/you/mlx-lm.git#my-branch
  --mlx-lm-src PATH                   Where --mlx-lm-git clones to (default: ~/mlx-lm-src).
                                      Must be the same path on every node.
  --force-pypi                        Install mlx-lm from PyPI even if an editable install
                                      is already present. This DISCARDS that checkout's
                                      local commits — only pass it deliberately.
  --no-disable-sleep                  Skip `sudo pmset -a disablesleep 1`. By default this
                                      runs so a MacBook Pro node stays awake lid-closed with
                                      no external display (needs sudo — run this script over
                                      `ssh -t`, not a plain non-interactive `ssh host cmd`,
                                      so the password prompt can appear).
  --dry-run                           Print what would happen; make no changes.
  -h, --help                          Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --python-version) PYTHON_VERSION="$2"; shift 2 ;;
    --venv-path) VENV_PATH="$2"; shift 2 ;;
    --mlx-lm-version) MLX_LM_VERSION="$2"; shift 2 ;;
    --mlx-lm-git) MLX_LM_GIT="$2"; shift 2 ;;
    --mlx-lm-src) MLX_LM_SRC="$2"; shift 2 ;;
    --force-pypi) FORCE_PYPI=1; shift ;;
    --no-disable-sleep) DISABLE_SLEEP=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -n "$MLX_LM_GIT" && -n "$MLX_LM_VERSION" ]]; then
  echo "ERROR: --mlx-lm-git and --mlx-lm-version are mutually exclusive" >&2
  exit 1
fi

run() {
  if (( DRY_RUN )); then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

echo "== configure_node.zsh on $(hostname) =="

# ---------- sleep (keep running lid-closed, no external display needed) ----------
if (( DISABLE_SLEEP )); then
  if pmset -g | grep -Eq '^\s*disablesleep\s+1'; then
    echo "Sleep already disabled (disablesleep=1)."
  else
    echo "Disabling sleep (sudo pmset -a disablesleep 1)..."
    run "sudo pmset -a disablesleep 1"
  fi
else
  echo "Skipping sleep-disable (--no-disable-sleep)."
fi

# ---------- Homebrew ----------
# A non-interactive `ssh host cmd` gets a minimal PATH that usually excludes
# /opt/homebrew/bin, so `command -v brew` alone reports Homebrew as missing on
# a machine that has it — and this script would then try to reinstall it. Look
# for the binary at its known locations before believing that.
for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  if [[ -x "$brew_bin" ]]; then
    eval "$("$brew_bin" shellenv)"
    break
  fi
done

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found — installing (may prompt for sudo password)..."
  run 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
else
  echo "Homebrew already installed: $(brew --version | head -1)"
fi

# ---------- Python ----------
PY_FORMULA="python@${PYTHON_VERSION}"
if ! brew list --versions "$PY_FORMULA" >/dev/null 2>&1; then
  echo "Installing $PY_FORMULA..."
  run "brew install $PY_FORMULA"
else
  echo "$PY_FORMULA already installed: $(brew list --versions "$PY_FORMULA")"
fi

PYTHON_BIN="$(brew --prefix)/opt/${PY_FORMULA}/bin/python${PYTHON_VERSION}"
if [[ ! -x "$PYTHON_BIN" && $DRY_RUN -eq 0 ]]; then
  echo "ERROR: expected python binary not found at $PYTHON_BIN" >&2
  exit 1
fi

# ---------- venv ----------
if [[ ! -d "$VENV_PATH" ]]; then
  echo "Creating venv at $VENV_PATH..."
  run "$PYTHON_BIN -m venv $VENV_PATH"
else
  echo "venv already exists at $VENV_PATH"
fi

VENV_PY="$VENV_PATH/bin/python"

# ---------- mlx / mlx-lm ----------
#
# Guard rails, both learned the hard way:
#
#   1. If mlx-lm is already an EDITABLE install (a git checkout on this
#      node), `pip install --upgrade mlx-lm` silently replaces it with the
#      PyPI wheel and throws away every local commit. Refuse by default.
#   2. Hand-edited files under site-packages are invisible to pip and are
#      deleted without warning by an upgrade. `.bak` files next to them are
#      the usual fingerprint of such an edit, so look before leaping.
#
# The durable fix for local changes is not "be careful here" — it's to
# carry them as commits on a fork branch and install that branch editable
# (--mlx-lm-git), so an upgrade is a merge instead of a silent revert.

# These checks are read-only, so they run under --dry-run too — a dry run is
# exactly when you want to be told that the real run would destroy something.
if [[ -x "$VENV_PY" ]]; then
  EDITABLE_LOC=$("$VENV_PY" -m pip show mlx-lm 2>/dev/null \
    | awk -F': ' '/^Editable project location:/{print $2}')
  if [[ -n "$EDITABLE_LOC" && -z "$MLX_LM_GIT" ]] && (( ! FORCE_PYPI )); then
    echo "NOTE: mlx-lm is an editable install from $EDITABLE_LOC."
    echo "      Skipping the pip upgrade — it would replace that checkout with"
    echo "      the PyPI wheel and discard any local commits. To update, pull"
    echo "      in that checkout. Pass --force-pypi to override deliberately."
    SKIP_MLX_LM=1
  fi

  # Surface hand-edits before an upgrade silently removes them. `.bak` files
  # are the fingerprint: pip has no idea the live file was edited, so an
  # upgrade overwrites it with no warning and no way back.
  SP_DIR=$("$VENV_PY" -c 'import site; print(site.getsitepackages()[0])' 2>/dev/null)
  if [[ -n "$SP_DIR" && -d "$SP_DIR" ]]; then
    BAKS_MLX=$(find "$SP_DIR/mlx" -name '*.bak' 2>/dev/null)
    BAKS_MLX_LM=$(find "$SP_DIR/mlx_lm" -name '*.bak' 2>/dev/null)
    if [[ -n "$BAKS_MLX$BAKS_MLX_LM" ]]; then
      echo "WARNING: local hand-edits detected under site-packages (.bak files present):"
      printf '%s\n' "$BAKS_MLX" "$BAKS_MLX_LM" | grep . | sed 's/^/         /'
      echo "         pip cannot see these. Extract them as diffs, then carry them"
      echo "         as commits on a fork branch (--mlx-lm-git) instead."
    fi
    # mlx ships compiled so it cannot be installed editable as easily, which
    # makes a patched file under site-packages the usual workaround — and
    # exactly the thing an upgrade destroys. Refuse rather than warn.
    if [[ -n "$BAKS_MLX" ]] && (( ! FORCE_PYPI )); then
      echo "NOTE: skipping the mlx upgrade — the hand-edits above would be lost."
      echo "      Pass --force-pypi to upgrade anyway (after saving those diffs)."
      SKIP_MLX=1
    fi
  fi
fi

run "$VENV_PY -m pip install --upgrade pip"

# mlx ships compiled, so it always comes from PyPI here.
if (( ! SKIP_MLX )); then
  echo "Installing/upgrading mlx in $VENV_PATH..."
  run "$VENV_PY -m pip install --upgrade mlx"
fi

if [[ -n "$MLX_LM_GIT" ]]; then
  # Editable install from a git checkout — the recommended path when you
  # carry local patches. MLX_LM_GIT is "URL#branch" or a local path.
  GIT_URL="${MLX_LM_GIT%%#*}"
  GIT_REF="${MLX_LM_GIT#*#}"
  [[ "$GIT_REF" == "$MLX_LM_GIT" ]] && GIT_REF=""
  echo "Installing mlx-lm as an editable git checkout at $MLX_LM_SRC..."
  if [[ -d "$MLX_LM_SRC/.git" ]]; then
    run "git -C $MLX_LM_SRC fetch --depth 1 origin ${GIT_REF:-HEAD}"
    run "git -C $MLX_LM_SRC checkout ${GIT_REF:-HEAD}"
    run "git -C $MLX_LM_SRC pull --ff-only"
  else
    run "git clone ${GIT_REF:+-b $GIT_REF} --depth 1 $GIT_URL $MLX_LM_SRC"
  fi
  run "$VENV_PY -m pip uninstall -y mlx-lm"
  run "$VENV_PY -m pip install -e $MLX_LM_SRC --no-deps"
elif (( ! SKIP_MLX_LM )); then
  MLX_LM_SPEC="mlx-lm"
  [[ -n "$MLX_LM_VERSION" ]] && MLX_LM_SPEC="mlx-lm==${MLX_LM_VERSION}"
  echo "Installing/upgrading $MLX_LM_SPEC in $VENV_PATH..."
  run "$VENV_PY -m pip install --upgrade $MLX_LM_SPEC"
fi

# ---------- report versions (for cross-node comparison) ----------
if (( DRY_RUN == 0 )); then
  echo "--- versions on $(hostname) ---"
  "$VENV_PY" --version
  "$VENV_PY" -m pip show mlx | grep -E '^(Name|Version)'
  # Editable location is included so a cross-node comparison catches the case
  # where one node is on a git checkout and the others are on the PyPI wheel —
  # every node must run identical code for the ring to work.
  "$VENV_PY" -m pip show mlx-lm | grep -E '^(Name|Version|Editable project location)'
  if [[ -d "$MLX_LM_SRC/.git" ]]; then
    echo "mlx-lm checkout: $(git -C "$MLX_LM_SRC" rev-parse --abbrev-ref HEAD) @ $(git -C "$MLX_LM_SRC" rev-parse --short HEAD)"
  fi
  echo "Python executable path: $VENV_PY"
fi

echo "== done on $(hostname) =="
