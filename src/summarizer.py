from .config import SUMMARY_MIN_MESSAGES, SUMMARY_TRIGGER
from .conversation_store import save_conversation
from .prompt_builder import build_summary_prompt, recent_messages


async def maybe_summarize(conversation, llm_client, base_url=None, model=None):
  messages = conversation.get("messages", [])
  if len(messages) < max(SUMMARY_MIN_MESSAGES, SUMMARY_TRIGGER):
    return conversation
  try:
    prompt = build_summary_prompt(conversation)
    summary_text = await llm_client.summarize(prompt, base_url=base_url, model=model)
    conversation["summary"] = summary_text
    conversation["messages"] = recent_messages(messages)
    save_conversation(conversation)
  except Exception:
    # best-effort; keep conversation as-is if summarization fails
    pass
  return conversation
