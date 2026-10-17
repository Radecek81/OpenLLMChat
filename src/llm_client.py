import httpx

from .config import (
  LLM_API_STYLE,
  ATTACHMENT_MODE,
  LLM_MAX_TOKENS,
  LLM_MAX_TOKENS_THINKING,
  LLM_BASE_URL,
  LLM_MODEL,
  LLM_IMAGE_INPUT_MODE,
  LLM_THINKING_DEFAULT_ENABLED,
  LLM_API_KEY,
  normalize_llm_base_url,
  REQUEST_TIMEOUT_SECONDS,
  SUPPORTS_ATTACHMENTS,
)


class LlmClient:
  def __init__(self):
    timeout = httpx.Timeout(connect=15.0, read=REQUEST_TIMEOUT_SECONDS, write=REQUEST_TIMEOUT_SECONDS, pool=30.0)
    self.client = httpx.AsyncClient(timeout=timeout, follow_redirects=False)

  def _normalized_base_url(self, base_url=None) -> str:
    normalized = normalize_llm_base_url(base_url or LLM_BASE_URL)
    if not normalized:
      raise ValueError("Chybí LLM URL. Nastav LLM_BASE_URL nebo povolený profil endpointu.")
    return normalized

  def _resolved_model(self, model=None) -> str:
    selected = (model or LLM_MODEL).strip() if isinstance(model, str) else (model or LLM_MODEL)
    if not selected:
      raise ValueError("Chybí název LLM modelu.")
    return selected

  def _auth_headers(self) -> dict:
    if not LLM_API_KEY:
      return {}
    return {"Authorization": f"Bearer {LLM_API_KEY}"}

  def _safe_response_text(self, response: httpx.Response, limit: int = 400) -> str:
    text = response.text[:limit]
    if LLM_API_KEY:
      text = text.replace(LLM_API_KEY, "****")
    return text

  def _chat_url(self, base_url=None) -> str:
    normalized = self._normalized_base_url(base_url)
    if LLM_API_STYLE == "openai":
      if normalized.endswith("/chat/completions"):
        return normalized
      if normalized.endswith("/v1"):
        return f"{normalized}/chat/completions"
      return f"{normalized}/v1/chat/completions"
    return normalized

  def _models_url(self, base_url=None) -> str:
    normalized = self._normalized_base_url(base_url)
    if LLM_API_STYLE == "openai":
      if normalized.endswith("/chat/completions"):
        return normalized[: -len("/chat/completions")] + "/models"
      if normalized.endswith("/v1"):
        return f"{normalized}/models"
      return f"{normalized}/v1/models"
    return normalized

  def _request_error_message(self, exc: Exception, url: str) -> str:
    name = exc.__class__.__name__
    detail = str(exc).strip()
    if not detail:
      detail = repr(exc)
    if isinstance(exc, httpx.ConnectTimeout):
      return f"Timeout pri navazovani spojeni s {url} ({name}: {detail})"
    if isinstance(exc, httpx.ReadTimeout):
      return f"LLM neodpovedel v limitu na {url} ({name}: {detail})"
    if isinstance(exc, httpx.ConnectError):
      return f"Nepodarilo se pripojit k {url} ({name}: {detail})"
    if isinstance(exc, httpx.RequestError):
      return f"Chyba HTTP pozadavku na {url} ({name}: {detail})"
    return f"{name}: {detail}"

  def _can_use_attachments(self) -> bool:
    if ATTACHMENT_MODE == "disable":
      return False
    if ATTACHMENT_MODE == "force":
      return True
    return SUPPORTS_ATTACHMENTS

  def _should_send_visual_media(self) -> bool:
    return LLM_IMAGE_INPUT_MODE in {"auto", "multimodal"}

  def _prepare_messages(self, messages, attachments, include_media=True):
    prepared = [dict(message) for message in messages]
    media_attachments = [
      attachment for attachment in attachments or []
      if attachment.get("mime_type", "").startswith(("image/", "video/"))
    ]
    if not include_media or not media_attachments or not prepared:
      return prepared

    last_message = dict(prepared[-1])
    if last_message.get("role") != "user":
      return prepared

    text_content = last_message.get("content", "")
    content_parts = []
    if isinstance(text_content, str) and text_content:
      content_parts.append({"type": "text", "text": text_content})
    elif isinstance(text_content, list):
      content_parts.extend(text_content)

    for attachment in media_attachments:
      mime_type = attachment.get("mime_type", "")
      data_url = f"data:{mime_type};base64,{attachment['data']}"
      if mime_type.startswith("image/"):
        content_parts.append(
          {
            "type": "image_url",
            "image_url": {
              "url": data_url,
            },
          }
        )
      elif mime_type.startswith("video/"):
        content_parts.append(
          {
            "type": "video_url",
            "video_url": {
              "url": data_url,
            },
          }
        )

    last_message["content"] = content_parts
    prepared[-1] = last_message
    return prepared

  def _attachments_for_body(self, attachments):
    if not attachments or not self._can_use_attachments():
      return None
    return [
      attachment for attachment in attachments
      if not attachment.get("mime_type", "").startswith(("image/", "video/"))
    ]

  def _max_tokens_for_mode(self, enable_thinking: bool) -> int:
    return LLM_MAX_TOKENS_THINKING if enable_thinking else LLM_MAX_TOKENS

  def _build_body(self, messages, attachments, params, include_media, enable_thinking, model=None):
    body = {
      "model": self._resolved_model(model),
      "messages": self._prepare_messages(messages, attachments, include_media=include_media),
      "max_tokens": self._max_tokens_for_mode(enable_thinking),
      "chat_template_kwargs": {
        "enable_thinking": enable_thinking,
      },
    }
    if params:
      body.update(params)
    request_attachments = self._attachments_for_body(attachments)
    if request_attachments:
      body["attachments"] = request_attachments
    return body

  def _is_unknown_image_modality(self, exc: httpx.HTTPStatusError) -> bool:
    if exc.response.status_code != 400:
      return False
    body = exc.response.text.lower()
    return "unknown modality: image" in body

  async def send_chat(self, messages, attachments=None, params=None, base_url=None, enable_thinking=None, model=None):
    url = self._chat_url(base_url)
    include_media = self._should_send_visual_media()
    if enable_thinking is None:
      enable_thinking = LLM_THINKING_DEFAULT_ENABLED
    body = self._build_body(
      messages,
      attachments,
      params,
      include_media=include_media,
      enable_thinking=enable_thinking,
      model=model,
    )
    try:
      response = await self.client.post(url, json=body, headers=self._auth_headers())
      response.raise_for_status()
      data = response.json()
      return self._extract_content(data)
    except httpx.HTTPStatusError as exc:
      if include_media and LLM_IMAGE_INPUT_MODE == "auto" and self._is_unknown_image_modality(exc):
        try:
          retry_body = self._build_body(
            messages,
            attachments,
            params,
            include_media=False,
            enable_thinking=enable_thinking,
            model=model,
          )
          retry_response = await self.client.post(url, json=retry_body, headers=self._auth_headers())
          retry_response.raise_for_status()
          retry_data = retry_response.json()
          return self._extract_content(retry_data)
        except httpx.HTTPStatusError as retry_exc:
          retry_snippet = self._safe_response_text(retry_exc.response)
          raise RuntimeError(
            f"LLM odmitlo obrazovy vstup a fallback selhal ({retry_exc.response.status_code} na {url}: {retry_snippet})"
          ) from retry_exc
        except ValueError as retry_exc:
          raise RuntimeError(f"Fallback po odmitnuti obrazku vratil nevalidni JSON z {url}: {retry_exc}") from retry_exc
        except Exception as retry_exc:
          raise RuntimeError(
            f"Fallback po odmitnuti obrazku selhal: {self._request_error_message(retry_exc, url)}"
          ) from retry_exc
      snippet = self._safe_response_text(exc.response)
      raise RuntimeError(f"LLM HTTP {exc.response.status_code} na {url}: {snippet}") from exc
    except ValueError as exc:
      raise RuntimeError(f"LLM vratilo nevalidni JSON z {url}: {exc}") from exc
    except Exception as exc:
      raise RuntimeError(f"LLM request failed: {self._request_error_message(exc, url)}") from exc

  async def summarize(self, messages, base_url=None, model=None):
    return await self.send_chat(
      messages,
      attachments=None,
      params={"max_tokens": 256, "temperature": 0.2},
      base_url=base_url,
      enable_thinking=False,
      model=model,
    )

  async def probe(self, base_url=None, model=None):
    url = self._models_url(base_url)
    selected_model = self._resolved_model(model)
    try:
      response = await self.client.get(url, headers=self._auth_headers())
      response.raise_for_status()
      data = response.json()
      model_ids = []
      if isinstance(data, dict) and isinstance(data.get("data"), list):
        model_ids = [item.get("id") for item in data["data"] if isinstance(item, dict)]
      exists = not model_ids or selected_model in model_ids
      return {
        "ok": exists,
        "url": url,
        "model": selected_model,
        "available_models": model_ids,
        "message": "Model je dostupny." if exists else "Endpoint je dostupny, ale model nebyl nalezen.",
      }
    except httpx.HTTPStatusError as exc:
      snippet = self._safe_response_text(exc.response)
      return {
        "ok": False,
        "url": url,
        "model": selected_model,
        "message": f"LLM HTTP {exc.response.status_code}: {snippet}",
      }
    except ValueError as exc:
      return {
        "ok": False,
        "url": url,
        "model": selected_model,
        "message": f"Nevalidni JSON z {url}: {exc}",
      }
    except Exception as exc:
      return {
        "ok": False,
        "url": url,
        "model": selected_model,
        "message": self._request_error_message(exc, url),
      }

  def _text_from_value(self, value) -> str:
    if isinstance(value, str):
      return value.strip()
    if isinstance(value, list):
      parts = []
      for item in value:
        if isinstance(item, str):
          parts.append(item)
          continue
        if not isinstance(item, dict):
          continue
        text = item.get("text")
        if isinstance(text, str):
          parts.append(text)
          continue
        nested = item.get("content")
        if isinstance(nested, str):
          parts.append(nested)
      return "".join(parts).strip()
    return ""

  def _extract_content(self, data):
    if isinstance(data, dict):
      if "choices" in data and data["choices"]:
        choice = data["choices"][0]
        message = choice.get("message") or choice
        content = self._text_from_value(message.get("content")) if isinstance(message, dict) else self._text_from_value(message)
        if content:
          return content
        if isinstance(message, dict):
          reasoning = self._text_from_value(message.get("reasoning")) or self._text_from_value(message.get("reasoning_content"))
          if reasoning:
            if choice.get("finish_reason") == "length":
              return (
                f"{reasoning}\n\n"
                "[Model vyčerpal limit tokenů během myšlení, takže finální odpověď nedokončil. "
                "Zkus vypnout Myšlení nebo zvýšit LLM_MAX_TOKENS.]"
              )
            return reasoning
      if "message" in data and isinstance(data["message"], dict):
        content = self._text_from_value(data["message"].get("content"))
        if content:
          return content
      content = self._text_from_value(data.get("content"))
      if content:
        return content
      reasoning = self._text_from_value(data.get("reasoning")) or self._text_from_value(data.get("reasoning_content"))
      if reasoning:
        return reasoning
    raise RuntimeError("Neznámý formát odpovědi LLM")

  async def close(self):
    await self.client.aclose()
