import asyncio
import traceback
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import List, Optional

from fastapi import FastAPI, File, Form, HTTPException, Query, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from . import attachment_processor
from .config import (
  ATTACHMENT_MODE,
  ALLOWED_LLM_BASE_URLS,
  CORS_ORIGINS,
  LLM_BASE_URL,
  LLM_MAX_TOKENS,
  LLM_MAX_TOKENS_THINKING,
  LLM_MODEL,
  LLM_THINKING_DEFAULT_ENABLED,
  MAX_ATTACHMENTS_PER_MESSAGE,
  MAX_FILE_SIZE_BYTES,
  MAX_TEXT_IN_PROMPT_PER_FILE,
  REQUEST_TIMEOUT_SECONDS,
  ROOT_DIR,
  SUPPORTS_ATTACHMENTS,
  SYSTEM_PROMPT,
  WINDOW_SIZE,
  normalize_llm_base_url,
)
from .conversation_store import (
  add_file_metadata,
  append_message,
  create_conversation,
  delete_conversation,
  list_conversations,
  load_conversation,
  save_conversation,
  validate_conversation_id,
)
from .llm_client import LlmClient
from .prompt_builder import build_prompt
from .summarizer import maybe_summarize

llm_client = LlmClient()


@asynccontextmanager
async def lifespan(_app: FastAPI):
  yield
  await llm_client.close()


app = FastAPI(lifespan=lifespan)

if CORS_ORIGINS:
  app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGINS,
    allow_credentials=False,
    allow_methods=["GET", "POST", "DELETE"],
    allow_headers=["Content-Type"],
  )

_conversation_locks: dict[str, asyncio.Lock] = {}


def _conversation_lock(conversation_id: str) -> asyncio.Lock:
  return _conversation_locks.setdefault(conversation_id, asyncio.Lock())


def _validated_conversation_id(conversation_id: str) -> str:
  try:
    return validate_conversation_id(conversation_id)
  except ValueError as exc:
    raise HTTPException(status_code=400, detail=str(exc)) from exc


def _allowed_llm_base_url(value: Optional[str]) -> str:
  try:
    candidate = normalize_llm_base_url(value or LLM_BASE_URL)
  except ValueError as exc:
    raise HTTPException(status_code=400, detail=str(exc)) from exc
  if not candidate:
    raise HTTPException(
      status_code=400,
      detail="LLM endpoint není nakonfigurován. Nastav LLM_BASE_URL.",
    )
  if candidate not in ALLOWED_LLM_BASE_URLS:
    raise HTTPException(
      status_code=403,
      detail="LLM endpoint není v LLM_ALLOWED_BASE_URLS.",
    )
  return candidate


@app.get("/api/health")
async def health():
  return {"ok": True}


@app.get("/api/llm-status")
async def llm_status(
  llm_base_url: Optional[str] = Query(default=None),
  llm_model: Optional[str] = Query(default=None),
):
  try:
    override_url = _allowed_llm_base_url(llm_base_url)
  except HTTPException as exc:
    return {
      "ok": False,
      "url": "",
      "model": (llm_model or LLM_MODEL).strip(),
      "max_model_len": None,
      "available_models": [],
      "message": str(exc.detail),
    }
  override_model = llm_model.strip() if llm_model else None
  return await llm_client.probe(base_url=override_url, model=override_model)


@app.get("/api/config")
async def config():
  return {
    "baseUrl": LLM_BASE_URL,
    "allowedBaseUrls": sorted(ALLOWED_LLM_BASE_URLS),
    "defaultThinkingEnabled": LLM_THINKING_DEFAULT_ENABLED,
    "maxTokens": LLM_MAX_TOKENS,
    "maxTokensThinking": LLM_MAX_TOKENS_THINKING,
    "model": LLM_MODEL,
    "window": WINDOW_SIZE,
    "maxAttachments": MAX_ATTACHMENTS_PER_MESSAGE,
    "maxFileSize": MAX_FILE_SIZE_BYTES,
    "maxTextPerFile": MAX_TEXT_IN_PROMPT_PER_FILE,
    "timeoutSeconds": REQUEST_TIMEOUT_SECONDS,
    "attachmentMode": ATTACHMENT_MODE,
    "supportsAttachments": SUPPORTS_ATTACHMENTS,
    "systemPrompt": SYSTEM_PROMPT,
  }


@app.get("/api/conversations")
async def list_api_conversations():
  return list_conversations()


@app.post("/api/conversations")
async def create_api_conversation():
  return create_conversation()


@app.delete("/api/conversations/{conversation_id}")
async def delete_api_conversation(conversation_id: str):
  conversation_id = _validated_conversation_id(conversation_id)
  async with _conversation_lock(conversation_id):
    try:
      delete_conversation(conversation_id)
    except FileNotFoundError:
      raise HTTPException(status_code=404, detail="Konverzace nenalezena")
  return {"ok": True, "id": conversation_id}


@app.get("/api/conversations/{conversation_id}")
async def get_conversation(conversation_id: str):
  conversation_id = _validated_conversation_id(conversation_id)
  try:
    return load_conversation(conversation_id)
  except FileNotFoundError:
    raise HTTPException(status_code=404, detail="Konverzace nenalezena")


async def _store_attachments(conversation_id: str, uploads: List[UploadFile]):
  if not uploads:
    return []
  if len(uploads) > MAX_ATTACHMENTS_PER_MESSAGE:
    raise HTTPException(status_code=400, detail="Příliš mnoho příloh v jedné zprávě")
  try:
    return await attachment_processor.store_attachments(conversation_id, uploads)
  except ValueError as exc:
    raise HTTPException(status_code=400, detail=str(exc))
  except Exception as exc:
    raise HTTPException(status_code=500, detail=f"Uložení souboru selhalo: {exc}")


@app.post("/api/conversations/{conversation_id}/messages")
async def send_message(
  conversation_id: str,
  content: str = Form(...),
  files: List[UploadFile] = File(default_factory=list),
  enable_thinking: bool = Form(default=LLM_THINKING_DEFAULT_ENABLED),
  llm_base_url: Optional[str] = Form(default=None),
  llm_model: Optional[str] = Form(default=None),
):
  conversation_id = _validated_conversation_id(conversation_id)
  override_url = _allowed_llm_base_url(llm_base_url)
  override_model = (llm_model or LLM_MODEL).strip()
  if not override_model:
    raise HTTPException(status_code=400, detail="LLM model není nakonfigurován.")

  async with _conversation_lock(conversation_id):
    try:
      conversation = load_conversation(conversation_id)
    except FileNotFoundError:
      raise HTTPException(status_code=404, detail="Konverzace nenalezena")

    attachment_meta = await _store_attachments(conversation_id, files)

    now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    user_message = {
      "role": "user",
      "content": content,
      "attachments": attachment_meta,
      "ts": now,
      "status": "sent",
    }
    append_message(conversation, user_message)
    for meta in attachment_meta:
      add_file_metadata(conversation, meta)
    save_conversation(conversation)

    attachment_block = ""
    attachments_payload = None
    if attachment_meta:
      attachment_block = attachment_processor.attachments_as_prompt_block(attachment_meta)
      attachments_payload = attachment_processor.attachments_as_payload(attachment_meta)

    prompt_messages = build_prompt(conversation, content, attachment_block, include_latest_messages=False)

    try:
      assistant_text = await llm_client.send_chat(
        prompt_messages,
        attachments_payload,
        base_url=override_url,
        enable_thinking=enable_thinking,
        model=override_model,
      )
      assistant_message = {
        "role": "assistant",
        "content": assistant_text,
        "attachments": [],
        "ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
      }
      append_message(conversation, assistant_message)
      save_conversation(conversation)
      await maybe_summarize(conversation, llm_client, base_url=override_url, model=override_model)
      return {
        "assistant": assistant_message,
        "conversation": conversation,
      }
    except Exception as exc:
      user_message["status"] = "error"
      save_conversation(conversation)
      detail = str(exc)
      traceback.print_exc()
      raise HTTPException(status_code=502, detail=detail)


static_dir = ROOT_DIR / "public"
static_dir.mkdir(exist_ok=True)
app.mount("/", StaticFiles(directory=static_dir, html=True), name="static")
