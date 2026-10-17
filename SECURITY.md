# Security policy

## Supported versions

Security fixes are applied to the latest version on the default branch.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's private vulnerability reporting feature after it is enabled for the repository, or contact the repository owner privately.

Include the affected version, reproduction steps, impact, and any suggested mitigation. Do not include real API keys, conversation content, or other private data.

## Deployment model

The web server is designed for a trusted local machine and binds to `127.0.0.1` by default. It does not implement user authentication. If it is made reachable from a LAN or the internet, an authenticated TLS reverse proxy and firewall restrictions are required.

Only endpoints explicitly configured through `LLM_BASE_URL` or `LLM_ALLOWED_BASE_URLS` can be called by the web UI. Keep API keys in environment variables or a secret manager and never commit them.

The macOS app stores saved API keys in Keychain. Debug output redacts supported authorization headers, but logs and conversation files may still contain sensitive prompts or model responses; handle them as private data.
