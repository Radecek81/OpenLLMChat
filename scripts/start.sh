#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$APP_ROOT"

APP_HOST="${APP_HOST:-127.0.0.1}"
APP_PORT="${APP_PORT:-8000}"
APP_PUBLIC_URL="${APP_PUBLIC_URL:-http://127.0.0.1:${APP_PORT}}"
AUTO_OPEN_BROWSER="${AUTO_OPEN_BROWSER:-true}"

if [ ! -d ".venv" ]; then
  echo "Chybí virtuální prostředí .venv. Spusť nejdřív scripts/install.sh"
  exit 1
fi

source .venv/bin/activate

open_browser() {
  if [ "$AUTO_OPEN_BROWSER" != "true" ]; then
    return
  fi

  (
    sleep 2
    if command -v open >/dev/null 2>&1; then
      open "$APP_PUBLIC_URL" >/dev/null 2>&1 || true
      exit 0
    fi
    if command -v xdg-open >/dev/null 2>&1; then
      xdg-open "$APP_PUBLIC_URL" >/dev/null 2>&1 || true
    fi
  ) &
}

echo "Aplikace poběží na ${APP_PUBLIC_URL}"
echo "Pokud se prohlížeč neotevře sám, otevři tuto adresu ručně."

open_browser
export APP_HOST APP_PORT APP_PUBLIC_URL AUTO_OPEN_BROWSER
exec python main.py "$@"
