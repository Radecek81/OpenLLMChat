"""OpenLLMChat entry point.

Copyright (C) 2026 Uberit s.r.o.
SPDX-License-Identifier: AGPL-3.0-only
Additional terms: ADDITIONAL_TERMS.md
"""

import os

import uvicorn

if __name__ == "__main__":
  host = os.getenv("APP_HOST", "127.0.0.1")
  port = int(os.getenv("APP_PORT", "8000"))
  reload_enabled = os.getenv("APP_RELOAD", "false").lower() == "true"
  uvicorn.run("src.server:app", host=host, port=port, reload=reload_enabled)
