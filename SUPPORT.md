# Support

Start with [Troubleshooting](docs/TROUBLESHOOTING.md) and the [supported configuration](docs/release/SUPPORT.md).

The current product boundary keeps Codex enabled and supports Claude Code as an optional second display source. Google Antigravity and Kimi Code remain unsupported and are not instantiated by production. Claude display can be disabled without changing `~/.claude`; relay installation and removal are separate confirmed operations with fingerprint-safe recovery and manual guidance when automatic mutation is unsafe.

When reporting a problem, identify **Codex**, **Claude Code**, **Claude relay installation/removal/manual recovery**, or **Other**, and state whether the issue concerns connection, quota freshness, presentation, or maintenance. Do not attach Claude `settings.json`, relay recovery backups, status-line payloads, account identifiers, or local paths.

After the repository is public, use GitHub Issues for reproducible non-sensitive bugs and feature requests. Use the private process in [SECURITY.md](SECURITY.md) for vulnerabilities. Never attach credentials, private prompts, Keychain exports, authentication files, or unredacted diagnostics.

Community support is provided on a best-effort basis. Provider interfaces and quota policies are controlled by their respective vendors. The MIT License does not include a warranty, uptime promise, compatibility guarantee, or paid support commitment. Windows, Intel Mac, Linux, and Mac App Store builds are outside this release.
