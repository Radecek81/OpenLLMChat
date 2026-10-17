#!/usr/bin/env bash
set -euo pipefail

RESOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_ROOT="$RESOURCE_ROOT/payload"
APP_SUPPORT_ROOT="${HOME}/Library/Application Support/LLM Chat"
APP_ROOT="${APP_SUPPORT_ROOT}/app"
VENV_ROOT="${APP_SUPPORT_ROOT}/.venv"
HASH_FILE="${APP_SUPPORT_ROOT}/requirements.sha256"
APP_PORT="${APP_PORT:-8000}"
APP_PUBLIC_URL="${APP_PUBLIC_URL:-http://127.0.0.1:${APP_PORT}}"
APP_RELOAD="${APP_RELOAD:-false}"
AUTO_OPEN_BROWSER="${AUTO_OPEN_BROWSER:-true}"

echo "LLM Chat bootstrap"
echo "Runtime: ${APP_SUPPORT_ROOT}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3 nebyl nalezen. Doinstaluj ho na cilovem Macu a spust aplikaci znovu."
  exit 1
fi

if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1; then
  echo "Je potreba Python 3.11 nebo novejsi. Aktualni python3 je prilis stary."
  exit 1
fi

mkdir -p "${APP_SUPPORT_ROOT}"

sync_payload() {
  mkdir -p "${APP_ROOT}"
  rsync -a --delete \
    --exclude ".venv" \
    --exclude "conversations" \
    --exclude "dist" \
    "${PAYLOAD_ROOT}/" "${APP_ROOT}/"
  mkdir -p "${APP_ROOT}/conversations"
}

install_deps() {
  local next_hash=""
  next_hash="$(shasum -a 256 "${APP_ROOT}/requirements.txt" | awk '{print $1}')"
  local current_hash=""
  if [ -f "${HASH_FILE}" ]; then
    current_hash="$(cat "${HASH_FILE}")"
  fi

  if [ ! -d "${VENV_ROOT}" ]; then
    python3 -m venv "${VENV_ROOT}"
  fi

  # shellcheck disable=SC1091
  source "${VENV_ROOT}/bin/activate"

  if [ "${next_hash}" != "${current_hash}" ]; then
    python -m pip install --upgrade pip
    pip install -r "${APP_ROOT}/requirements.txt"
    printf '%s' "${next_hash}" > "${HASH_FILE}"
  fi
}

open_browser() {
  if [ "${AUTO_OPEN_BROWSER}" != "true" ]; then
    return
  fi
  (
    sleep 2
    open "${APP_PUBLIC_URL}" >/dev/null 2>&1 || true
  ) &
}

port_busy() {
  lsof -n -iTCP:"${APP_PORT}" -sTCP:LISTEN >/dev/null 2>&1
}

sync_payload
install_deps

if port_busy; then
  echo "Na portu ${APP_PORT} uz neco bezi. Oteviram ${APP_PUBLIC_URL}."
  open_browser
  exit 0
fi

echo "Spoustim aplikaci na ${APP_PUBLIC_URL}"
open_browser

cd "${APP_ROOT}"
# shellcheck disable=SC1091
source "${VENV_ROOT}/bin/activate"
export APP_PORT APP_PUBLIC_URL APP_RELOAD AUTO_OPEN_BROWSER=false
exec python main.py
