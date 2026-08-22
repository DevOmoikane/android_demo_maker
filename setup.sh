#!/usr/bin/env bash
# Bootstrap the Demo Maker Web Studio environment.
#
#   1. find a suitable Python (>= 3.8): uv first, then pyenv, then a scan of
#      common system locations; if nothing qualifies, offer to install uv
#      (user-local, no sudo) so it can fetch a managed Python
#   2. create .venv/ in this directory (reused when already valid)
#   3. install requirements.txt into it (empty today)
#   4. run demo_maker.doctor: checks external tools, asks before installing,
#      can download a Piper voice model when requested
#
# Usage:
#   ./setup.sh              interactive prompts for anything missing
#   ./setup.sh --yes        assume yes for every prompt (scripted setups)
#   ./setup.sh --check      doctor only, no environment changes
#
# Compatible with macOS stock bash 3.2.
set -e

cd "$(dirname "$0")"

ASSUME_YES=0
CHECK_ONLY=0
RECREATE=0
for arg in "$@"; do
    case "$arg" in
        --yes) ASSUME_YES=1 ;;
        --check) CHECK_ONLY=1 ;;
        --recreate) RECREATE=1 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

info() { printf '==> %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
die()  { printf '[error] %s\n' "$*" >&2; exit 1; }

ask() {
    if [ "$ASSUME_YES" = "1" ]; then return 0; fi
    printf '%s [y/N] ' "$1"
    read -r REPLY || return 1
    case "$REPLY" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

python_ok() {  # python_ok <interpreter> -> 0 when it runs and is >= 3.8
    "$1" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1
}

newest_version() {  # newest_version <v1> <v2> ... -> prints the highest
    printf '%s\n' "$@" | awk '
        function ge(an, bn,    i, a, b) {
            for (i = 1; i <= ((an > bn) ? an : bn); i++) {
                a = (i <= an) ? V[i] : 0
                b = (i <= bn) ? B[i] : 0
                if (a > b) return 1
                if (a < b) return 0
            }
            return 0
        }
        {
            n = split($0, V, ".")
            if (NR == 1 || ge(n, bn)) {
                for (i = 1; i <= n; i++) B[i] = V[i] + 0
                bn = n
                best = $0
            }
        }
        END { print best }'
}

find_system_python() {
    local c
    for c in \
        /usr/bin/python3 \
        /opt/homebrew/bin/python3 \
        /usr/local/bin/python3 \
        /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 \
        /opt/homebrew/bin/python3.11 /opt/homebrew/bin/python3.10 \
        /opt/homebrew/bin/python3.9 \
        /usr/local/bin/python3.13 /usr/local/bin/python3.12 \
        /usr/local/bin/python3.11 /usr/local/bin/python3.10 \
        /usr/local/bin/python3.9 \
        python3 python3.13 python3.12 python3.11 python3.10 \
        python3.9 python3.8; do
        if command -v "$c" >/dev/null 2>&1 && python_ok "$c"; then
            command -v "$c"
            return 0
        fi
    done
    return 1
}

find_pyenv_python() {  # sets PYENV_PY on success
    command -v pyenv >/dev/null 2>&1 || return 1
    local versions best prefix pybin
    versions=$(pyenv versions --bare 2>/dev/null \
        | grep -E '^3\.(8|9|[12][0-9])\.[0-9]+$') || return 1
    [ -n "$versions" ] || return 1
    best=$(newest_version $versions)
    [ -n "$best" ] || return 1
    prefix="$(pyenv prefix "$best" 2>/dev/null)" || return 1
    pybin="$prefix/bin/python"
    if [ -x "$pybin" ] && python_ok "$pybin"; then
        PYENV_PY="$pybin"
        return 0
    fi
    return 1
}

create_with_uv() {
    local syspy
    syspy="$(find_system_python || true)"
    if [ -n "$syspy" ]; then
        uv venv --seed --python "$syspy" .venv
    else
        # no usable system interpreter: let uv pick or download one
        uv venv --seed .venv
    fi
}

install_uv_and_create() {
    command -v curl >/dev/null 2>&1 \
        || die "curl is required to install uv (or install Python manually)"
    ask "No suitable Python found. Install uv (user-local, no sudo) so it can provide one?" \
        || die "Aborted: no way to obtain a Python >= 3.8."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
    hash -r
    command -v uv >/dev/null 2>&1 || die "uv installer ran but uv is not on PATH"
    create_with_uv
}

ensure_venv() {
    if [ -x .venv/bin/python ] && python_ok .venv/bin/python; then
        if [ "$RECREATE" != "1" ]; then
            info "Using existing .venv"
            return 0
        fi
        info "Recreating .venv (--recreate)"
        rm -rf .venv
    elif [ -e .venv ]; then
        warn ".venv exists but its interpreter is unusable; recreating"
        rm -rf .venv
    fi

    # 1) uv: preferred, seeds pip and can download a managed interpreter
    if command -v uv >/dev/null 2>&1; then
        info "Creating virtual environment with uv"
        if create_with_uv; then
            finish_venv_setup
            return 0
        fi
        warn "uv venv failed; trying other methods"
        rm -rf .venv
    fi

    # 2) pyenv: newest installed version >= 3.8
    if find_pyenv_python; then
        info "Using pyenv Python: $PYENV_PY"
        "$PYENV_PY" -m venv .venv
    elif command -v pyenv >/dev/null 2>&1; then
        latest="$(pyenv install --list 2>/dev/null | tr -d ' ' \
            | grep -E '^3\.([89]|[12][0-9])\.[0-9]+$' | tail -n 1)"
        if [ -n "$latest" ] && ask "pyenv has no Python >= 3.8 installed. Install $latest now?"; then
            pyenv install "$latest" && pyenv rehash
            find_pyenv_python || die "pyenv finished installing but no usable Python found"
            info "Using pyenv Python: $PYENV_PY"
            "$PYENV_PY" -m venv .venv
        fi
    fi

    # 3) plain scan of system locations
    if [ ! -x .venv/bin/python ]; then
        syspy="$(find_system_python || true)"
        if [ -n "$syspy" ]; then
            info "Using system Python: $syspy"
            "$syspy" -m venv .venv
        fi
    fi

    # 4) last resort: get uv so it can provide an interpreter
    if [ ! -x .venv/bin/python ]; then
        if command -v uv >/dev/null 2>&1; then
            info "No system interpreter found; letting uv download one"
            uv venv --seed .venv
        else
            install_uv_and_create
        fi
    fi

    [ -x .venv/bin/python ] || die "Could not create a virtual environment"
    finish_venv_setup
}

finish_venv_setup() {
    # non-uv venvs may lack pip entirely (e.g. Debian without python3-pip)
    if ! .venv/bin/python -m pip --version >/dev/null 2>&1; then
        info "Bootstrapping pip via ensurepip"
        .venv/bin/python -m ensurepip --upgrade >/dev/null
    fi
}

if [ "$CHECK_ONLY" = "1" ]; then
    PYC=".venv/bin/python"
    if [ ! -x "$PYC" ]; then
        PYC="$(find_system_python || echo python3)"
    fi
    exec "$PYC" -m demo_maker.doctor --check
fi

echo "Demo Maker setup"
ensure_venv

info "Installing requirements.txt"
.venv/bin/python -m pip install --quiet --disable-pip-version-check --upgrade pip || warn "pip self-upgrade skipped"
.venv/bin/python -m pip install --quiet --disable-pip-version-check -r requirements.txt

info "Running environment doctor"
DOCTOR_ARGS=""
[ "$ASSUME_YES" = "1" ] && DOCTOR_ARGS="--yes"
.venv/bin/python -m demo_maker.doctor $DOCTOR_ARGS

echo
echo "All set. Launch the studio with:"
echo "    ./run.sh"
