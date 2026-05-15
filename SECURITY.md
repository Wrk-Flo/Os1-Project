# Security Policy

Hermes Desktop - OS1 Edition is a local macOS app that can connect to cloud
computers, SSH hosts, LLM providers, Telegram bots, Composio, AgentMail, and
OpenAI Realtime voice. Treat it as operator software with real access to
machines and accounts.

## Reporting Vulnerabilities

Please do not open a public issue for a vulnerability or leaked credential.
Email security@orgo.ai with:

- affected version or commit
- reproduction steps
- expected and actual behavior
- logs or screenshots with secrets redacted

We will acknowledge reports within 7 days when possible.

## Secret Handling

- API keys are stored in the macOS Keychain where supported.
- `.env`, key, certificate, and release artifacts are ignored by Git.
- Realtime voice keeps `OPENAI_API_KEY` server-side in the local Swift
  endpoint; the browser surface sends only SDP to the local endpoint.
- Orgo MCP credentials stay in the Swift app process and are passed only to
  the local MCP subprocess.

## Voice Tool Safety

The public default Realtime voice MCP surface is intentionally bounded:

- enabled toolsets: `core,screen,files`
- disabled by default: `orgo_upload_file`
- `shell` and `admin` require explicit opt-in with
  `OS1_REALTIME_ORGO_TOOLSETS`

Only enable shell/admin tools for agents and computers you are comfortable
letting a voice model operate.
