#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${GHOST_SEARXNG_ROOT:-$HOME/.local/share/ghost/searxng}"
BIND_ADDRESS="${GHOST_SEARXNG_BIND:-127.0.0.1}"
PORT="${GHOST_SEARXNG_PORT:-8888}"

usage() {
  cat >&2 <<'EOF'
Usage: search_setup.sh [--install-system-deps] [--clone] [--configure] [--run]

Native SearXNG setup for Ghost. Docker is intentionally not used.

Environment:
  GHOST_SEARXNG_ROOT   install directory, default ~/.local/share/ghost/searxng
  GHOST_SEARXNG_BIND   bind address, default 127.0.0.1
  GHOST_SEARXNG_PORT   port, default 8888
EOF
}

install_system_deps() {
  sudo apt install -y \
    python3-dev python3-babel python3-venv \
    libxml2-dev libxslt1-dev zlib1g-dev libffi-dev libssl-dev
}

clone_and_install() {
  mkdir -p "$(dirname "$ROOT_DIR")"
  if [ ! -d "$ROOT_DIR/.git" ]; then
    git clone https://github.com/searxng/searxng.git "$ROOT_DIR"
  fi
  cd "$ROOT_DIR"
  python3 -m venv local/pyenv
  # shellcheck disable=SC1091
  source local/pyenv/bin/activate
  pip install -U pip setuptools wheel
  pip install -r requirements.txt -r requirements-server.txt
  pip install --no-build-isolation -e .
}

configure() {
  cd "$ROOT_DIR"
  if [ ! -f searxng/settings.yml ]; then
    if [ -f searx/settings.yml ]; then
      mkdir -p searxng
      cp searx/settings.yml searxng/settings.yml
    else
      echo "settings.yml not found under $ROOT_DIR" >&2
      return 1
    fi
  fi
  python3 - "$BIND_ADDRESS" "$PORT" <<'PY'
from pathlib import Path
import re
import sys

bind, port = sys.argv[1], sys.argv[2]
for path in (Path("searxng/settings.yml"), Path("searx/settings.yml")):
    if not path.exists():
        continue
    text = path.read_text()
    text = re.sub(r"bind_address:\s*['\"]?[^'\"\n]+['\"]?", f"bind_address: \"{bind}\"", text)
    text = re.sub(r"port:\s*[0-9]+", f"port: {port}", text)
    text = re.sub(r"method:\s*['\"]?[^'\"\n]+['\"]?", "method: \"GET\"", text)
    text = re.sub(r"formats:\n(?:\s+-\s+\w+\n)+", "formats:\n    - html\n    - json\n", text, count=1)
    if "ultrasecretkey" in text:
        import secrets
        text = text.replace("ultrasecretkey", secrets.token_urlsafe(32))
    path.write_text(text)
PY
}

run_server() {
  cd "$ROOT_DIR"
  # shellcheck disable=SC1091
  source local/pyenv/bin/activate
  if [ -f searxng/webapp.py ]; then
    exec python searxng/webapp.py
  fi
  exec python searx/webapp.py
}

if [ "$#" -eq 0 ]; then
  usage
  exit 0
fi

for arg in "$@"; do
  case "$arg" in
    --install-system-deps) install_system_deps ;;
    --clone) clone_and_install ;;
    --configure) configure ;;
    --run) run_server ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "unknown option: $arg" >&2
      usage
      exit 2
      ;;
  esac
done
