from typing import Dict, List

from .config import SUMMARY_PROMPT, SYSTEM_PROMPT, WINDOW_SIZE


def recent_messages(messages: List[Dict]) -> List[Dict]:
  if not messages:
    return []
  return messages[-WINDOW_SIZE:]


def build_prompt(
  conversation: Dict,
  user_content: str,
  attachment_block: str = "",
  system_prompt: str = SYSTEM_PROMPT,
  include_latest_messages: bool = True,
) -> List[Dict]:
  prompt_messages: List[Dict] = []
  if system_prompt:
    prompt_messages.append({"role": "system", "content": system_prompt})
  summary = conversation.get("summary")
  if summary:
    prompt_messages.append({"role": "system", "content": f"Conversation summary: {summary}"})
  history = recent_messages(conversation.get("messages", []))
  if not include_latest_messages and history:
    history = history[:-1]
  prompt_messages.extend(history)
  content = user_content.strip()
  if attachment_block:
    content = f"{content}\n\nAttached files:\n{attachment_block}"
  prompt_messages.append({"role": "user", "content": content})
  return prompt_messages


def build_summary_prompt(conversation: Dict) -> List[Dict]:
  messages = conversation.get("messages", [])
  window = recent_messages(messages)
  older = messages[: len(messages) - len(window)]
  system = SYSTEM_PROMPT
  prompt = [
    {"role": "system", "content": SUMMARY_PROMPT},
  ]
  existing_summary = conversation.get("summary")
  if existing_summary:
    prompt.append({"role": "system", "content": f"Existing summary: {existing_summary}"})
  prompt.extend(older)
  prompt.append({"role": "user", "content": "Please summarize the conversation above."})
  return prompt
