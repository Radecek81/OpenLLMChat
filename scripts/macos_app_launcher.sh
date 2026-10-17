#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOOTSTRAP_SCRIPT="${BUNDLE_ROOT}/Resources/bootstrap_macos.sh"

if [ ! -x "${BOOTSTRAP_SCRIPT}" ]; then
  osascript -e 'display alert "LLM Chat" message "Chybi bootstrap_macos.sh v balicku aplikace." as critical'
  exit 1
fi

open -a Terminal "${BOOTSTRAP_SCRIPT}"
