#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$APP_ROOT"

echo "[1/4] Kontrola Pythonu..."
if ! command -v python3 >/dev/null 2>&1; then
  echo "Python3 nebyl nalezen. Na Ubuntu nainstaluj: sudo apt update && sudo apt install -y python3 python3-venv python3-pip"
  exit 1
fi

echo "[2/4] Vytvářím venv (.venv)..."
if ! python3 -m venv .venv 2>/tmp/venv.log; then
  cat /tmp/venv.log
  echo "Nejde vytvořit venv. Na Ubuntu doinstaluj balík python3-venv: sudo apt install -y python3-venv"
  exit 1
fi

echo "[3/4] Aktivace venv a upgrade pipu..."
source .venv/bin/activate
pip install --upgrade pip

echo "[4/4] Instalace závislostí..."
pip install -r requirements.txt

echo "Hotovo. Spusť aplikaci: scripts/start.sh"
