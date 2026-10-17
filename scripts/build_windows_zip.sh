#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_ROOT="${APP_ROOT}/dist/windows"
STAGE_NAME="LLM Chat Windows"
STAGE_ROOT="${DIST_ROOT}/${STAGE_NAME}"
ZIP_PATH="${DIST_ROOT}/llm-chat-windows.zip"

mkdir -p "${DIST_ROOT}"
rm -rf "${STAGE_ROOT}" "${ZIP_PATH}"

mkdir -p "${STAGE_ROOT}/payload"

cp "${APP_ROOT}/scripts/bootstrap_windows.ps1" "${STAGE_ROOT}/bootstrap_windows.ps1"
cp "${APP_ROOT}/scripts/windows_app_launcher.cmd" "${STAGE_ROOT}/LLM Chat.cmd"
cp "${APP_ROOT}/INSTALL-Windows.txt" "${STAGE_ROOT}/"

rsync -a \
  --exclude ".venv" \
  --exclude ".git" \
  --exclude ".github" \
  --exclude ".build" \
  --exclude ".build-dist" \
  --exclude "conversations" \
  --exclude "dist" \
  --exclude "reports" \
  --exclude "research_notes" \
  --exclude "__pycache__" \
  --exclude "*.pyc" \
  --exclude "*.dmg" \
  --exclude "*.zip" \
  --exclude "llm-chat-ubuntu.tar.gz" \
  "${APP_ROOT}/" "${STAGE_ROOT}/payload/"

export DIST_ROOT STAGE_ROOT ZIP_PATH
python3 - <<'PY'
import os
from pathlib import Path
import zipfile

dist_root = Path(os.environ["DIST_ROOT"])
stage_root = Path(os.environ["STAGE_ROOT"])
zip_path = Path(os.environ["ZIP_PATH"])

with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(stage_root.rglob("*")):
        archive.write(path, path.relative_to(dist_root))
PY

echo "Vytvoreno: ${ZIP_PATH}"
