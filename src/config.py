import os
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

ROOT_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = Path(os.getenv("LLM_CHAT_DATA_DIR", str(ROOT_DIR / "conversations")))
DATA_DIR.mkdir(parents=True, exist_ok=True)
try:
  DATA_DIR.chmod(0o700)
except OSError:
  pass

SYSTEM_PROMPT = (
  "You are a concise local assistant. Keep responses short but helpful."
)
SUMMARY_PROMPT = (
  "Summarize the conversation so far. Keep key decisions, tasks, and any files "
  "that were referenced by name. Do not include small talk. Be under 120 words."
)

WINDOW_SIZE = int(os.getenv("CHAT_WINDOW_SIZE", "10"))
SUMMARY_TRIGGER = int(os.getenv("SUMMARY_TRIGGER", "18"))
SUMMARY_MIN_MESSAGES = int(os.getenv("SUMMARY_MIN_MESSAGES", "8"))

MAX_ATTACHMENTS_PER_MESSAGE = int(os.getenv("MAX_ATTACHMENTS_PER_MESSAGE", "3"))
MAX_FILE_SIZE_BYTES = int(os.getenv("MAX_FILE_SIZE_BYTES", str(10 * 1024 * 1024)))
MAX_TEXT_IN_PROMPT_PER_FILE = int(os.getenv("MAX_TEXT_IN_PROMPT_PER_FILE", str(12000)))

ALLOWED_MIME_TYPES = set(
  os.getenv(
    "ALLOWED_MIME_TYPES",
    ",".join(
      [
        "text/plain",
        "text/markdown",
        "text/csv",
        "text/html",
        "text/css",
        "text/javascript",
        "text/graphql",
        "application/json",
        "application/xml",
        "text/xml",
        "application/javascript",
        "application/pdf",
        "application/msword",
        "application/vnd.ms-excel",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "image/png",
        "image/jpeg",
        "image/gif",
        "image/webp",
        "audio/mpeg",
        "audio/mp3",
        "audio/wav",
        "audio/x-wav",
        "video/mp4",
        "video/x-msvideo",
      ]
    ),
  ).split(",")
)

LLM_BASE_URL = os.getenv("LLM_BASE_URL", "").strip()
LLM_MODEL = os.getenv("LLM_MODEL", "").strip()
LLM_API_STYLE = os.getenv("LLM_API_STYLE", "openai")
LLM_IMAGE_INPUT_MODE = os.getenv("LLM_IMAGE_INPUT_MODE", "multimodal")
ATTACHMENT_MODE = os.getenv("LLM_ATTACHMENT_MODE", "auto")
SUPPORTS_ATTACHMENTS = os.getenv("LLM_SUPPORTS_ATTACHMENTS", "false").lower() == "true"
REQUEST_TIMEOUT_SECONDS = float(os.getenv("LLM_TIMEOUT_SECONDS", "900"))
LLM_MAX_TOKENS = int(os.getenv("LLM_MAX_TOKENS", "4096"))
LLM_MAX_TOKENS_THINKING = int(os.getenv("LLM_MAX_TOKENS_THINKING", "8192"))
LLM_THINKING_DEFAULT_ENABLED = os.getenv("LLM_THINKING_DEFAULT_ENABLED", "false").lower() == "true"
LLM_API_KEY = os.getenv("LLM_API_KEY", "")


def normalize_llm_base_url(value: str) -> str:
  candidate = (value or "").strip().rstrip("/")
  if not candidate:
    return ""
  parts = urlsplit(candidate)
  if parts.scheme not in {"http", "https"} or not parts.hostname:
    raise ValueError("LLM URL musí být platná adresa s protokolem http nebo https.")
  if parts.username or parts.password or parts.query or parts.fragment:
    raise ValueError("LLM URL nesmí obsahovat přihlašovací údaje, query ani fragment.")
  return urlunsplit((parts.scheme.lower(), parts.netloc.lower(), parts.path.rstrip("/"), "", ""))


def _configured_allowed_urls() -> set[str]:
  raw_values = [LLM_BASE_URL]
  raw_values.extend(os.getenv("LLM_ALLOWED_BASE_URLS", "").split(","))
  allowed = set()
  for raw_value in raw_values:
    if raw_value.strip():
      allowed.add(normalize_llm_base_url(raw_value))
  return allowed


ALLOWED_LLM_BASE_URLS = _configured_allowed_urls()
CORS_ORIGINS = [
  value.strip()
  for value in os.getenv("APP_CORS_ORIGINS", "").split(",")
  if value.strip()
]
