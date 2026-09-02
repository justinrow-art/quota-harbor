# Privacy

The canonical privacy notice is [docs/release/PRIVACY.md](docs/release/PRIVACY.md).

In short: QuotaHarbor contains no advertising, analytics, tracking SDK, direct HTTP client, or publisher-operated network service. The current product boundary keeps Codex enabled and lets the user optionally display Claude Code. Production instantiates only those two connectors; Google Antigravity and Kimi Code remain unsupported and are not instantiated. Claude integration uses the local CLI authentication-state command and an explicitly confirmed local `statusLine` relay.

The app does not extract, display, or upload passwords, tokens, conversations, prompts, or session files. Its verified Codex child may communicate with OpenAI under the user's existing agreement. When Claude is enabled, the app runs only `claude auth status` with fixed arguments and reads the allow-listed quota cache produced by its relay. Installing or removing that relay requires separate confirmation and bounded, local-only reads/writes of Claude `settings.json`, a fingerprint manifest, and a complete backup. The backup may contain user-added secrets; the app does not parse or upload those unrelated values. See the canonical notice for paths, `0700`/`0600` permissions, retention, fingerprint-safe mutation, and manual recovery.
