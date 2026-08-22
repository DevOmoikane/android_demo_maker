#!/usr/bin/env bash
# Launch the Demo Maker Web Studio using the project virtual environment.
# Usage: ./run.sh [--debug]   (extra flags are forwarded to demo_maker)
set -e
cd "$(dirname "$0")"

PY=".venv/bin/python"
if [ ! -x "$PY" ]; then
    echo "error: no virtual environment found at .venv" >&2
    echo "Run ./setup.sh first." >&2
    exit 1
fi

exec "$PY" -m demo_maker "$@"
