// Copyright (C) 2026 Uberit s.r.o.
// SPDX-License-Identifier: AGPL-3.0-only
// Additional terms: ../ADDITIONAL_TERMS.md

const state = {
  config: null,
  conversationId: null,
  conversations: [],
  enableThinking: false,
  llmBaseUrl: '',
  llmModel: '',
  llmStatus: null,
  messages: [],
  attachments: [],
  summary: '',
};

const elements = {
  messages: document.getElementById('messages'),
  empty: document.getElementById('emptyState'),
  messageInput: document.getElementById('messageInput'),
  sendButton: document.getElementById('sendButton'),
  fileButton: document.getElementById('fileButton'),
  fileInput: document.getElementById('fileInput'),
  attachmentChips: document.getElementById('attachmentChips'),
  conversationList: document.getElementById('conversationList'),
  hint: document.getElementById('hint'),
  llmUrlButton: document.getElementById('llmUrlButton'),
  llmUrlForm: document.getElementById('llmUrlForm'),
  llmUrlInput: document.getElementById('llmUrlInput'),
  llmModelInput: document.getElementById('llmModelInput'),
  llmModelOptions: document.getElementById('llmModelOptions'),
  modelTag: document.getElementById('modelTag'),
  newChatButton: document.getElementById('newChatButton'),
  summaryTag: document.getElementById('summaryTag'),
  thinkingToggle: document.getElementById('thinkingToggle'),
};

const fmtBytes = (bytes) => {
  if (bytes === 0) return '0 B';
  const sizes = ['B', 'KB', 'MB', 'GB'];
  const i = Math.floor(Math.log(bytes) / Math.log(1024));
  return `${(bytes / Math.pow(1024, i)).toFixed(1)} ${sizes[i]}`;
};

const ts = (iso) => new Date(iso).toLocaleTimeString('cs-CZ', { hour: '2-digit', minute: '2-digit' });
const shortDate = (iso) => new Date(iso).toLocaleString('cs-CZ', {
  day: '2-digit',
  month: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
});

async function init() {
  elements.sendButton.addEventListener('click', handleSend);
  elements.fileButton.addEventListener('click', () => elements.fileInput.click());
  elements.fileInput.addEventListener('change', handleFiles);
  elements.llmUrlForm.addEventListener('submit', applyLlmSettings);
  elements.thinkingToggle.addEventListener('change', handleThinkingToggle);
  elements.newChatButton.addEventListener('click', () => {
    createNewConversation().catch((err) => {
      elements.hint.textContent = `Nový chat se nepodařilo vytvořit: ${err.message || err}`;
      elements.newChatButton.disabled = false;
    });
  });
  elements.messageInput.addEventListener('keydown', (ev) => {
    if (ev.key === 'Enter' && !ev.shiftKey) {
      ev.preventDefault();
      handleSend();
    }
  });

  state.config = await fetchJson('/api/config');
  state.enableThinking = (localStorage.getItem('enableThinking') ?? String(state.config.defaultThinkingEnabled)) === 'true';
  state.llmBaseUrl = localStorage.getItem('llmBaseUrl') || state.config.baseUrl || '';
  state.llmModel = localStorage.getItem('llmModel') || state.config.model || '';
  elements.llmUrlInput.value = state.llmBaseUrl;
  elements.llmModelInput.value = state.llmModel;
  elements.thinkingToggle.checked = state.enableThinking;
  state.llmStatus = await fetchLlmStatus();
  updateModelOptions();
  updateMeta();
  await ensureConversation();
}

function updateMeta() {
  const activeModel = state.llmModel || state.config?.model || 'n/a';
  elements.modelTag.textContent = `Model: ${activeModel}`;
  const summaryText = state?.summary ? 'Shrnutí aktivní' : 'Shrnutí se vytvoří později';
  elements.summaryTag.textContent = summaryText;
  const activeUrl = state.llmBaseUrl || state.config?.baseUrl || 'n/a';
  const thinkingState = state.enableThinking ? 'Myšlení zapnuto' : 'Myšlení vypnuto';
  const limits = `Max ${state.config?.maxAttachments} příloh · ${fmtBytes(state.config?.maxFileSize || 0)} na soubor · ${thinkingState}`;
  const availableModels = Array.isArray(state.llmStatus?.available_models) && state.llmStatus.available_models.length
    ? ` · Dostupné modely: ${state.llmStatus.available_models.join(', ')}`
    : '';
  if (state.llmStatus?.ok) {
    elements.hint.textContent = `${limits} · LLM připojeno · ${activeUrl}${availableModels}`;
  } else if (state.llmStatus?.message) {
    elements.hint.textContent = `${limits} · LLM chyba: ${state.llmStatus.message}${availableModels}`;
  } else {
    elements.hint.textContent = limits;
  }
}

function updateModelOptions() {
  elements.llmModelOptions.innerHTML = '';
  const activeModel = state.llmModel || state.config?.model || '';
  const models = new Set(state.llmStatus?.available_models || []);
  if (activeModel) {
    models.add(activeModel);
  }
  for (const model of models) {
    const option = document.createElement('option');
    option.value = model;
    elements.llmModelOptions.appendChild(option);
  }
}

function handleThinkingToggle() {
  state.enableThinking = elements.thinkingToggle.checked;
  localStorage.setItem('enableThinking', String(state.enableThinking));
  updateMeta();
}

async function fetchLlmStatus() {
  const url = new URL('/api/llm-status', window.location.origin);
  if (state.llmBaseUrl) {
    url.searchParams.set('llm_base_url', state.llmBaseUrl);
  }
  if (state.llmModel) {
    url.searchParams.set('llm_model', state.llmModel);
  }
  return fetchJson(url.toString());
}

async function applyLlmSettings(ev) {
  ev.preventDefault();
  const nextUrl = elements.llmUrlInput.value.trim();
  const nextModel = elements.llmModelInput.value.trim();
  state.llmBaseUrl = nextUrl || state.config.baseUrl || '';
  state.llmModel = nextModel || state.config.model || '';
  localStorage.setItem('llmBaseUrl', state.llmBaseUrl);
  localStorage.setItem('llmModel', state.llmModel);
  elements.llmUrlButton.disabled = true;
  try {
    state.llmStatus = await fetchLlmStatus();
    updateModelOptions();
    updateMeta();
  } catch (err) {
    elements.hint.textContent = `LLM nastavení chyba: ${err.message || err}`;
  } finally {
    elements.llmUrlButton.disabled = false;
  }
}

async function ensureConversation() {
  const stored = localStorage.getItem('conversationId');
  await refreshConversations();
  const exists = state.conversations.find((c) => c.id === stored);
  if (exists) {
    state.conversationId = stored;
  } else if (state.conversations.length > 0) {
    state.conversationId = state.conversations[0].id;
  } else {
    const created = await fetchJson('/api/conversations', { method: 'POST' });
    state.conversationId = created.id;
    await refreshConversations();
  }
  localStorage.setItem('conversationId', state.conversationId);
  await loadConversation();
}

async function refreshConversations() {
  state.conversations = await fetchJson('/api/conversations');
  renderConversationList();
}

async function loadConversation() {
  if (!state.conversationId) {
    state.messages = [];
    state.summary = '';
    updateMeta();
    renderConversationList();
    renderMessages();
    return;
  }
  const convo = await fetchJson(`/api/conversations/${state.conversationId}`);
  state.messages = convo.messages || [];
  state.summary = convo.summary;
  updateMeta();
  renderConversationList();
  renderMessages();
}

function renderConversationList() {
  elements.conversationList.innerHTML = '';
  if (!state.conversations.length) {
    const empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = 'Zatím žádné konverzace.';
    elements.conversationList.appendChild(empty);
    return;
  }

  state.conversations.forEach((conversation) => {
    const item = document.createElement('div');
    item.className = `conversation-item ${conversation.id === state.conversationId ? 'active' : ''}`;
    item.addEventListener('click', async () => {
      if (conversation.id === state.conversationId) return;
      state.conversationId = conversation.id;
      localStorage.setItem('conversationId', state.conversationId);
      state.attachments = [];
      renderAttachmentChips();
      await loadConversation();
      elements.messageInput.focus();
    });

    const main = document.createElement('div');
    main.className = 'conversation-main';

    const title = document.createElement('div');
    title.className = 'conversation-title';
    title.textContent = conversation.title || 'Nový chat';

    const preview = document.createElement('div');
    preview.className = 'conversation-preview';
    preview.textContent = conversation.preview || 'Bez zpráv';

    const meta = document.createElement('div');
    meta.className = 'conversation-meta';
    meta.textContent = `${conversation.message_count || 0} zpráv · ${shortDate(conversation.updated_at || conversation.created_at)}`;

    main.appendChild(title);
    main.appendChild(preview);
    main.appendChild(meta);

    const remove = document.createElement('button');
    remove.className = 'conversation-delete';
    remove.type = 'button';
    remove.title = 'Smazat chat';
    remove.textContent = '×';
    remove.addEventListener('click', async (ev) => {
      ev.stopPropagation();
      await deleteConversation(conversation.id);
    });

    item.appendChild(main);
    item.appendChild(remove);
    elements.conversationList.appendChild(item);
  });
}

async function createNewConversation() {
  elements.newChatButton.disabled = true;
  try {
    const created = await fetchJson('/api/conversations', { method: 'POST' });
    state.conversationId = created.id;
    state.attachments = [];
    state.messages = [];
    state.summary = '';
    elements.messageInput.value = '';
    localStorage.setItem('conversationId', state.conversationId);
    renderAttachmentChips();
    await refreshConversations();
    await loadConversation();
    elements.messageInput.focus();
  } finally {
    elements.newChatButton.disabled = false;
  }
}

async function deleteConversation(conversationId) {
  const target = state.conversations.find((item) => item.id === conversationId);
  const title = target?.title || 'tento chat';
  if (!window.confirm(`Smazat ${title}?`)) {
    return;
  }

  await fetchJson(`/api/conversations/${conversationId}`, { method: 'DELETE' });

  if (state.conversationId === conversationId) {
    state.conversationId = null;
  }

  await refreshConversations();

  if (!state.conversationId) {
    if (state.conversations.length > 0) {
      state.conversationId = state.conversations[0].id;
    }
    if (state.conversationId) {
      localStorage.setItem('conversationId', state.conversationId);
    } else {
      localStorage.removeItem('conversationId');
    }
    await loadConversation();
    elements.messageInput.focus();
  } else {
    renderConversationList();
  }
}

function renderMessages() {
  elements.messages.innerHTML = '';
  if (!state.messages.length) {
    elements.empty.classList.remove('hidden');
    elements.empty.textContent = state.conversationId
      ? 'Napiš první zprávu a přidej soubor přes sponku.'
      : 'Vyber chat vlevo nebo vytvoř nový.';
    return;
  }
  elements.empty.classList.add('hidden');
  state.messages.forEach((msg) => {
    const li = document.createElement('li');
    li.className = `message ${msg.role}`;

    const metaRow = document.createElement('div');
    metaRow.className = 'meta-row';
    const who = msg.role === 'user' ? 'Ty' : 'Asistent';
    const time = msg.ts ? ts(msg.ts) : '';
    metaRow.textContent = `${who} · ${time}`;

    const statusLabel = msg.status === 'error' ? 'chyba' : msg.status === 'sending' ? 'odesílám…' : 'hotovo';
    const status = document.createElement('span');
    status.className = `status ${msg.status || 'done'}`;
    status.textContent = statusLabel;
    metaRow.appendChild(status);

    const body = document.createElement('div');
    body.className = 'body';
    body.textContent = msg.content;

    li.appendChild(metaRow);
    li.appendChild(body);

    if (msg.attachments && msg.attachments.length) {
      const list = document.createElement('div');
      list.className = 'attachments-list';
      msg.attachments.forEach((att) => {
        const chip = document.createElement('div');
        chip.className = 'attachment-pill';
        chip.textContent = `${att.filename} (${fmtBytes(att.size_bytes || att.sizeBytes || 0)})`;
        list.appendChild(chip);
      });
      li.appendChild(list);
    }
    elements.messages.appendChild(li);
  });
  elements.messages.scrollTop = elements.messages.scrollHeight;
}

function renderAttachmentChips() {
  elements.attachmentChips.innerHTML = '';
  state.attachments.forEach((file, index) => {
    const chip = document.createElement('div');
    chip.className = 'attachment-chip';
    chip.textContent = `${file.name} (${fmtBytes(file.size)})`;
    const remove = document.createElement('button');
    remove.textContent = '×';
    remove.addEventListener('click', () => {
      state.attachments.splice(index, 1);
      renderAttachmentChips();
    });
    chip.appendChild(remove);
    elements.attachmentChips.appendChild(chip);
  });
}

async function handleFiles(ev) {
  const files = Array.from(ev.target.files || []);
  const max = state.config?.maxAttachments || 0;
  for (const file of files) {
    if (state.attachments.length >= max) {
      elements.hint.textContent = 'Limit příloh vyčerpán';
      break;
    }
    if (file.size > state.config.maxFileSize) {
      elements.hint.textContent = `${file.name} je příliš velký`;
      continue;
    }
    state.attachments.push(file);
  }
  elements.fileInput.value = '';
  renderAttachmentChips();
}

async function handleSend() {
  const text = elements.messageInput.value.trim();
  if (!text && !state.attachments.length) return;
  elements.sendButton.disabled = true;
  elements.newChatButton.disabled = true;
  const tempMessage = {
    role: 'user',
    content: text,
    attachments: state.attachments.map((f) => ({ filename: f.name, size_bytes: f.size })),
    ts: new Date().toISOString(),
    status: 'sending',
  };
  state.messages.push(tempMessage);
  renderMessages();

  const form = new FormData();
  form.append('content', text);
  form.append('enable_thinking', String(state.enableThinking));
  form.append('llm_base_url', state.llmBaseUrl || state.config.baseUrl || '');
  form.append('llm_model', state.llmModel || state.config.model || '');
  state.attachments.forEach((file) => form.append('files', file));

  try {
    const res = await fetch(`/api/conversations/${state.conversationId}/messages`, {
      method: 'POST',
      body: form,
    });
    if (!res.ok) {
      throw new Error(await readError(res));
    }
    const data = await res.json();
    state.messages = data.conversation.messages;
    state.summary = data.conversation.summary;
    state.llmStatus = { ok: true, message: 'Model odpověděl.' };
    updateModelOptions();
    elements.messageInput.value = '';
    state.attachments = [];
    await refreshConversations();
    renderAttachmentChips();
    renderMessages();
    updateMeta();
  } catch (err) {
    tempMessage.status = 'error';
    elements.hint.textContent = `Chyba: ${err.message || err}`;
    renderMessages();
  } finally {
    elements.sendButton.disabled = false;
    elements.newChatButton.disabled = false;
  }
}

async function readError(res) {
  const raw = await res.text();
  try {
    const parsed = JSON.parse(raw);
    return parsed.detail || parsed.message || raw;
  } catch {
    return raw;
  }
}

async function fetchJson(url, options = {}) {
  const res = await fetch(url, options);
  if (!res.ok) {
    throw new Error(await res.text());
  }
  return res.json();
}

init().catch((err) => {
  elements.hint.textContent = `Start selhal: ${err.message}`;
});
