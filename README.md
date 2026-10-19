# Open LLM chat

Open LLM chat is a self-hosted chat client for OpenAI-compatible language-model APIs. It includes a native SwiftUI client for macOS and a lightweight FastAPI web client for macOS, Linux, and Windows.

No provider, private endpoint, model, or API key is built in. Configuration stays under the user's control.

The native macOS client streams responses token by token, provides immediate Stop/cancel, keeps reasoning separate from the final answer, exposes Off/Low/High reasoning modes, shows the endpoint actually used after routing, and uses validated structured outputs for generated conversation titles and summaries.

The **P2–P4** panel adds provider-neutral configuration for an embedding-backed knowledge index, hybrid dense/lexical retrieval with source ranges, PDF and office-document extraction, push-to-talk transcription, TTS playback with fallback, and an authenticated HTTP MCP gateway. Credentials for embedding, speech, and MCP services are stored in Keychain. High-risk P4 capabilities remain off by default and require a compatible backend, sandbox, approval policy, and deployment-specific validation before use.

## Features

- OpenAI-compatible chat completions, plus Ollama, Anthropic, and Gemini interfaces in the macOS client
- multiple file-backed conversations
- text, image, audio, video, PDF, and office-document attachments
- rolling context and optional automatic summaries
- optional thinking mode and configurable token limits
- native macOS credential storage in Keychain
- versioned endpoint profiles with capability metadata, context-limit checks, and optional failover
- local-only web server by default
- exact endpoint allowlist for the web client

## macOS app

Requirements: macOS 13 or later and a Swift 6 toolchain for source builds.

```bash
swift run --package-path swift-macos
```

Enter the provider URL, model, interface, and optional API key in the app. Saved secrets are stored in macOS Keychain; `settings.json` contains only a credential reference and a masked hint. Conversations remain in:

```text
~/Library/Application Support/LLM Chat Swift/
```

Save two or more provider profiles and enable **Automatic fallback** in the Advanced panel to use ordered failover. Only connection failures, timeouts, HTTP 429, and HTTP 5xx move to the next saved profile; authentication, request-schema, and other HTTP 4xx errors do not. A profile discovered to have an insufficient context window is skipped, and repeatedly failing endpoints enter a short circuit-breaker cooldown.

Build an ad-hoc signed DMG:

```bash
./scripts/build_macos_dmg.sh
```

For a Developer ID build, set `MACOS_SIGNING_IDENTITY` to the certificate name. Distribution outside the App Store still requires Apple's normal notarization process.

## Web app

Requirements: Python 3.11 or later.

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
cp .env.example .env
```

Load the environment file in your shell, or export at least `LLM_BASE_URL` and `LLM_MODEL`, then start:

```bash
export LLM_BASE_URL=http://127.0.0.1:11434/v1
export LLM_MODEL=your-model-name
./scripts/start.sh
```

Open [http://127.0.0.1:8000](http://127.0.0.1:8000).

The web UI may only select URLs listed in `LLM_ALLOWED_BASE_URLS`; `LLM_BASE_URL` is included automatically. The check uses exact normalized URLs. This prevents a browser user from turning the backend and its API key into a proxy to arbitrary services.

Example with two permitted providers:

```bash
export LLM_BASE_URL=http://127.0.0.1:11434/v1
export LLM_ALLOWED_BASE_URLS=http://127.0.0.1:11434/v1,https://api.example.com/v1
export LLM_MODEL=your-model-name
export LLM_API_KEY='set-this-outside-source-control'
./scripts/start.sh
```

See [.env.example](.env.example) for the remaining limits and model options.

## Network security

The FastAPI server binds to `127.0.0.1` and disables CORS by default. If another origin must access the API, set an explicit comma-separated `APP_CORS_ORIGINS` value.

Do not expose the built-in server directly to the internet. For LAN or internet access, put it behind an authenticated TLS reverse proxy, restrict firewall access, and then explicitly set `APP_HOST`. Read [SECURITY.md](SECURITY.md) before deployment.

## Storage

The web client stores each conversation as `conversations/<id>.json` and attachments under `conversations/<id>/files/`. Writes are atomic, IDs are validated, and operations on the same conversation are serialized. Set `LLM_CHAT_DATA_DIR` to use another location.

Runtime data, local environment files, virtual environments, build output, and packaged releases are excluded from Git.

## Tests

```bash
python -m unittest discover -s tests -v
swift test --package-path swift-macos
node --check public/app.js
bash -n scripts/*.sh
```

GitHub Actions runs the Python suite on Linux, macOS, and Windows, the Swift suite on macOS, and static JavaScript and shell checks.

## Packaging

```bash
./scripts/build_macos_dmg.sh
./scripts/build_windows_zip.sh
```

The Windows archive excludes local build caches, private runtime data, research notes, and release artifacts.

## Project layout

```text
public/        browser UI
src/           FastAPI backend and OpenAI-compatible client
swift-macos/   native SwiftUI app
scripts/       installation, startup, and packaging scripts
tests/         backend security and concurrency tests
```

## License and attribution

OpenLLMChat is free software licensed under the [GNU Affero General Public License v3.0](LICENSE).
Private and commercial use is permitted under the license. Distributed modifications and modified
versions made available to users over a network must provide their corresponding source code under
the AGPL-3.0.

Copyright (C) 2026 Uberit s.r.o. All interactive versions must preserve the required attribution
described in [ADDITIONAL_TERMS.md](ADDITIONAL_TERMS.md). Third-party components are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Contributions are accepted under AGPL-3.0 together with the
project's additional attribution terms.
