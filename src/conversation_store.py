import json
import os
import re
import shutil
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List

from .config import DATA_DIR

CONVERSATION_ID_PATTERN = re.compile(r"^[a-f0-9]{32}$")


def validate_conversation_id(conversation_id: str) -> str:
  if not CONVERSATION_ID_PATTERN.fullmatch(conversation_id or ""):
    raise ValueError("Neplatné ID konverzace")
  return conversation_id


def _conversation_path(conversation_id: str) -> Path:
  return DATA_DIR / f"{validate_conversation_id(conversation_id)}.json"


def _conversation_dir(conversation_id: str) -> Path:
  return DATA_DIR / validate_conversation_id(conversation_id)


def create_conversation() -> Dict:
  conversation_id = uuid.uuid4().hex
  created_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
  payload = {
    "id": conversation_id,
    "created_at": created_at,
    "updated_at": created_at,
    "summary": "",
    "messages": [],
    "files": [],
  }
  save_conversation(payload)
  return payload


def _conversation_title(conversation: Dict) -> str:
  for message in conversation.get("messages", []):
    if message.get("role") == "user":
      content = (message.get("content") or "").strip()
      if content:
        return content[:48]
  summary = (conversation.get("summary") or "").strip()
  if summary:
    return summary[:48]
  return "Nový chat"


def _conversation_preview(conversation: Dict) -> str:
  messages = conversation.get("messages", [])
  if not messages:
    return "Bez zpráv"
  content = (messages[-1].get("content") or "").strip()
  return content[:72] if content else "Bez textu"


def list_conversations() -> List[Dict]:
  conversations = []
  for path in DATA_DIR.glob("*.json"):
    try:
      with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
        conversations.append(
          {
            "id": data.get("id"),
            "created_at": data.get("created_at"),
            "updated_at": data.get("updated_at", data.get("created_at")),
            "summary": data.get("summary", ""),
            "title": _conversation_title(data),
            "preview": _conversation_preview(data),
            "message_count": len(data.get("messages", [])),
          }
        )
    except json.JSONDecodeError:
      continue
  conversations.sort(key=lambda item: item.get("updated_at", item.get("created_at", "")), reverse=True)
  return conversations


def load_conversation(conversation_id: str) -> Dict:
  path = _conversation_path(conversation_id)
  if not path.exists():
    raise FileNotFoundError(f"Conversation {conversation_id} not found")
  with path.open("r", encoding="utf-8") as handle:
    return json.load(handle)


def save_conversation(conversation: Dict) -> None:
  conversation_id = conversation["id"]
  path = _conversation_path(conversation_id)
  _conversation_dir(conversation_id).mkdir(parents=True, exist_ok=True)
  try:
    _conversation_dir(conversation_id).chmod(0o700)
  except OSError:
    pass
  messages = conversation.get("messages", [])
  if messages:
    conversation["updated_at"] = messages[-1].get("ts", conversation.get("created_at"))
  else:
    conversation["updated_at"] = conversation.get("updated_at", conversation.get("created_at"))
  temporary_path = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
  try:
    with temporary_path.open("w", encoding="utf-8") as handle:
      try:
        temporary_path.chmod(0o600)
      except OSError:
        pass
      json.dump(conversation, handle, ensure_ascii=False, indent=2)
      handle.flush()
      os.fsync(handle.fileno())
    os.replace(temporary_path, path)
  finally:
    if temporary_path.exists():
      temporary_path.unlink()


def append_message(conversation: Dict, message: Dict) -> None:
  conversation.setdefault("messages", []).append(message)


def add_file_metadata(conversation: Dict, metadata: Dict) -> None:
  conversation.setdefault("files", []).append(metadata)


def delete_conversation(conversation_id: str) -> None:
  path = _conversation_path(conversation_id)
  directory = _conversation_dir(conversation_id)
  if not path.exists():
    raise FileNotFoundError(f"Conversation {conversation_id} not found")
  path.unlink()
  if directory.exists():
    shutil.rmtree(directory)
