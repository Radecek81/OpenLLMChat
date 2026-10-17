import base64
import hashlib
import json
import mimetypes
from pathlib import Path
from typing import Dict, List

from fastapi import UploadFile

from .config import (
  ALLOWED_MIME_TYPES,
  DATA_DIR,
  MAX_FILE_SIZE_BYTES,
  MAX_TEXT_IN_PROMPT_PER_FILE,
)
from .conversation_store import _conversation_dir

TEXT_MIME_TYPES = {
  "application/json",
  "application/xml",
  "application/javascript",
  "text/xml",
}


def _files_dir(conversation_id: str) -> Path:
  return _conversation_dir(conversation_id) / "files"


def _safe_filename(name: str) -> str:
  return Path(name).name.replace(" ", "_")


def _sha256_bytes(data: bytes) -> str:
  digest = hashlib.sha256()
  digest.update(data)
  return digest.hexdigest()


def _build_stored_path(conversation_id: str, attachment_id: str, filename: str) -> Path:
  return _files_dir(conversation_id) / f"{attachment_id}_{_safe_filename(filename)}"


def _resolve_stored_path(metadata: Dict) -> Path:
  raw_path = Path(metadata["stored_path"])
  if raw_path.is_absolute():
    raise ValueError("Neplatná cesta k příloze.")
  if raw_path.parts and raw_path.parts[0] == DATA_DIR.name:
    raw_path = Path(*raw_path.parts[1:])
  data_root = DATA_DIR.resolve()
  candidate = (data_root / raw_path).resolve()
  if candidate != data_root and data_root not in candidate.parents:
    raise ValueError("Neplatná cesta k příloze.")
  return candidate


def _resolve_mime_type(upload: UploadFile) -> str:
  if upload.content_type:
    return upload.content_type
  guessed, _ = mimetypes.guess_type(upload.filename or "")
  return guessed or "application/octet-stream"


def is_text_mime_type(mime_type: str) -> bool:
  return mime_type.startswith("text/") or mime_type in TEXT_MIME_TYPES


def is_image_mime_type(mime_type: str) -> bool:
  return mime_type.startswith("image/")


def is_video_mime_type(mime_type: str) -> bool:
  return mime_type.startswith("video/")


def validate_mime_type(upload: UploadFile) -> None:
  mime_type = _resolve_mime_type(upload)
  if mime_type not in ALLOWED_MIME_TYPES and not mime_type.startswith(("text/", "image/", "audio/", "video/")):
    raise ValueError("Nepodporovaný typ souboru; pošli textový formát nebo povolený MIME.")


def validate_size(size_bytes: int) -> None:
  if size_bytes > MAX_FILE_SIZE_BYTES:
    raise ValueError("Soubor je příliš velký.")


def _decode_text(content: bytes, mime_type: str) -> str:
  try:
    text = content.decode("utf-8")
  except UnicodeDecodeError:
    text = content.decode("latin-1", errors="ignore")
  if mime_type in {"application/json", "application/xml", "text/xml"}:
    try:
      parsed = json.loads(text)
      return json.dumps(parsed, indent=2)
    except Exception:
      return text
  return text


def _truncate_text(text: str) -> str:
  if len(text) <= MAX_TEXT_IN_PROMPT_PER_FILE:
    return text
  head = text[:MAX_TEXT_IN_PROMPT_PER_FILE]
  return f"{head}\n...[zbytek oříznut kvůli limitu {MAX_TEXT_IN_PROMPT_PER_FILE} znaků]"


async def store_attachments(conversation_id: str, uploads: List[UploadFile]) -> List[Dict]:
  stored: List[Dict] = []
  directory = _files_dir(conversation_id)
  directory.mkdir(parents=True, exist_ok=True)
  for upload in uploads:
    validate_mime_type(upload)
    mime_type = _resolve_mime_type(upload)
    chunks = []
    size_bytes = 0
    while True:
      chunk = await upload.read(min(1024 * 1024, MAX_FILE_SIZE_BYTES + 1 - size_bytes))
      if not chunk:
        break
      chunks.append(chunk)
      size_bytes += len(chunk)
      validate_size(size_bytes)
    content = b"".join(chunks)
    attachment_id = upload.filename and _sha256_bytes(content)[:12]
    attachment_id = attachment_id or _sha256_bytes(content)[:12]
    stored_path = _build_stored_path(conversation_id, attachment_id, upload.filename or "file")
    stored_path.write_bytes(content)
    try:
      stored_path.chmod(0o600)
    except OSError:
      pass
    metadata = {
      "attachment_id": attachment_id,
      "filename": _safe_filename(upload.filename or "file"),
      "mime_type": mime_type,
      "size_bytes": size_bytes,
      "stored_path": str(stored_path.relative_to(DATA_DIR)),
      "sha256": _sha256_bytes(content),
    }
    stored.append(metadata)
  return stored


def load_attachment_text(metadata: Dict) -> str:
  path = _resolve_stored_path(metadata)
  content = path.read_bytes()
  text = _decode_text(content, metadata.get("mime_type", "text/plain"))
  return _truncate_text(text)


def attachment_block(metadata: Dict) -> str:
  header = (
    f"Attachment #{metadata['attachment_id']}: {metadata['filename']} "
    f"({metadata['mime_type']}, {metadata['size_bytes']} B)\n"
  )
  mime_type = metadata.get("mime_type", "application/octet-stream")
  if is_text_mime_type(mime_type):
    text = load_attachment_text(metadata)
    return (
      f"{header}"
      "--- BEGIN ATTACHMENT CONTENT ---\n"
      f"{text}\n"
      "--- END ATTACHMENT CONTENT ---"
    )
  if is_image_mime_type(mime_type):
    return (
      f"{header}"
      "--- IMAGE ATTACHMENT ---\n"
      "Image content is stored separately; if the backend supports vision it is sent as multimodal input.\n"
      "--- END IMAGE ATTACHMENT ---"
    )
  if is_video_mime_type(mime_type):
    return (
      f"{header}"
      "--- VIDEO ATTACHMENT ---\n"
      "Video content is stored separately; if the backend supports video input it is sent as multimodal input.\n"
      "--- END VIDEO ATTACHMENT ---"
    )
  return (
    f"{header}"
    "--- BINARY ATTACHMENT METADATA ---\n"
    "Binary content is not inlined into the prompt. Use filename, MIME type, and any native backend attachment support.\n"
    "--- END BINARY ATTACHMENT METADATA ---"
  )


def attachments_as_prompt_block(attachments: List[Dict]) -> str:
  blocks = [attachment_block(item) for item in attachments]
  return "\n\n".join(blocks)


def attachments_as_payload(attachments: List[Dict]) -> List[Dict]:
  payloads = []
  for meta in attachments:
    path = _resolve_stored_path(meta)
    content = path.read_bytes()
    payloads.append(
      {
        "id": meta["attachment_id"],
        "filename": meta["filename"],
        "mime_type": meta["mime_type"],
        "data": base64.b64encode(content).decode("ascii"),
      }
    )
  return payloads
