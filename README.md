# Harnais

Multiple Claude, Codex, and Cursor accounts on a Mac, without typing config
paths. Harnais creates isolated profiles, runs the official login, installs
PATH wrappers, publishes quotas for [Iles](https://github.com/basique-industrie/iles),
and can emit T3 Code provider instances.

Harnais is not an agent control surface. T3 Code remains the thread runtime.

## Connections

The Connections tab groups tools as **Shared**, **Added**, and **Built-in**, with
icons, search, account filtering, and per-account warnings under **Manage**.
Shared connections keep one Harnais login across Claude, Codex, Cursor, and OpenCode.
Added tools keep their provider settings; built-in tools remain provider-bundled.

Use **Add connection** or an Added connection's **Share login** action. Harnais
supports Google Drive, Gmail, Outlook, Slack, Grafana, Atlassian, and custom OAuth-enabled Streamable
HTTP MCP servers. Manage shared settings, sign-in, and account sync centrally.
Provider-specific plugins and cloud-hosted connectors are not automatically portable.

Credentials stay under `~/.harnais/integrations/`. Each provider gets a local adapter:

```json
"harnais-google-drive-personal": {
  "command": "/Users/you/.harnais/bin/harnais",
  "args": ["mcp", "serve", "harnais-google-drive-personal"]
}
```

Each adapter uses its own MCP session with the shared credential. Concurrent token
refresh is serialized. Sync preserves unrelated settings and refuses name collisions.
Existing direct connections remain until you disable them in their provider settings.
Tool approvals may still be required in each provider.

See [shared connections architecture, migration, and limitations](docs/shared-connections.md) and the [product OAuth registration guide](docs/oauth-app-registration.md).

Shared connections default to Harnais's product registration. Personal and Work are
connection labels, not separate developer apps. Google's desktop client is bundled;
public Google sign-in remains subject to OAuth verification. Drive uses the stable
Drive, Sheets, Docs and Slides APIs and does not require MCP preview eligibility.
Slack public distribution requires Marketplace approval. Atlassian registers
its native client automatically. Grafana uses a URL and service-account token.

Advanced custom app settings retain existing Personal and Work registrations.
Confidential custom secrets stay local. Bundled native client material is separate
from user credentials; never commit `~/.harnais/oauth-clients.json` or tokens.

## What it owns

- Account profiles under `~/.harnais/profiles/`
- Official `claude auth login`, `codex login`, and `agent login` with the
  right environment already set
- Wrappers in `~/.harnais/bin` (`harnais`, `claude-work`, `codex-personal`, `agent-work`)
- `~/.harnais/quotas.json` for Iles
- Drive / Slack / Grafana / Atlassian connections shared across harnesses
- Account colors, with an optional matching accent in T3 Code.
- Signed in-app updates in the shipped app; check manually from About or the app menu.
- Optional merge of extra accounts into T3 Code `providerInstances` (vendor defaults map to T3's built-in slots). When T3 is open, Harnais updates it through T3 itself. Profiles already in T3 stay updated.
- T3 sign-in status for each account, one-click Cursor sign-in to T3, and T3-managed ChatGPT accounts in Usage

## Rules the UI never asks you to know

In **Binaries**, each CLI shows whether your terminal uses the same installation.
Matching installations show **Ready to run**. If another installation is in use,
**Switch to v…** makes Harnais's installation the default in new zsh terminals,
including after mise changes the PATH. Under **Details**, turn off **Keep
command-line updates in sync** to restore normal PATH selection.
The preference adds a marked block to `.zshrc` and links in
`~/.harnais/terminal-bin`; it does not remove package-manager settings. Expand
**Details** to inspect or copy the paths.

OpenCode supports default-login import, isolated profiles, terminal wrappers,
CLI updates, T3 export, and MCP connections. Its isolated profiles use separate
XDG data, config, cache, and state directories. OpenCode's account view lists saved provider logins and their authentication
method, with email and plan details when the login includes them. API-key logins
may not include those details; OpenCode Zen and Go accounts link to the dashboard.
OpenCode quota and spend tracking are not available yet.

- Claude uses `CLAUDE_CONFIG_DIR`. Never `HOME`.
- Codex defaults to a separate `CODEX_HOME`. An optional T3 shadow home
  keeps auth private while sharing Codex history.
- Cursor second accounts use `CURSOR_CONFIG_DIR` and a file credential store.
  T3 Code Nightly 0.0.46+ runs Cursor through its own SDK and ignores that
  profile. When all installed T3 builds use the SDK, Harnais exports a named
  provider with a stable ID and removes obsolete CLI settings. Installing a
  CLI build retains or restores those settings for compatibility.
  Harnais offers T3 sign-in after adding a Cursor profile. You can also use
  **T3 sign-in → Sign in…** on the account's Settings tab. The terminal and
  Harnais usage limits use the Harnais login; T3's SDK has its own login.

## Build

macOS 26 SDK and a Swift 6.2 toolchain:

```bash
./scripts/run.sh
./scripts/test.sh
```

`./scripts/package.sh --dev` builds an ad-hoc-signed `dist/Harnais Dev.app`.
`--shipped` uses `com.jean.harnais`. Both share `~/.harnais`.

The product OAuth registration catalog is injected by the protected release build
and excluded from source control. When building from source, use Advanced custom
app settings for your own registrations. Existing saved connections still work.

To release, bump the version and build in `Sources/HarnaisCore/Info.plist`,
add a matching `## X.Y.Z` section to `CHANGELOG.md`, and push a `vX.Y.Z` tag.
Harnais's Release workflow builds, signs, notarizes and publishes the zip and
checksum after approval of its protected `release` environment. It uses the
repository's automatic GitHub token; no personal token is needed.
See [the release guide](docs/RELEASE.md) for setup, validation and retries with `gh`.

## CLI

```bash
harnais list
harnais connections
harnais import-defaults
harnais import-mcp
harnais add claude|codex|cursor|opencode --label Work [--import-default] [--t3-shadow]
harnais connect google-drive|gmail|outlook|slack|atlassian|grafana --label Work
harnais disconnect <mcp-name>
harnais wrappers
harnais path
harnais quotas
harnais t3-apply
harnais iles-extension
harnais mcp apply
harnais mcp serve <name>
```

## Local data

| Data | Path |
| --- | --- |
| Accounts | `~/.harnais/accounts.json` |
| Settings | `~/.harnais/settings.json` |
| Connections | `~/.harnais/integrations.json` |
| OAuth clients | `~/.harnais/oauth-clients.json` |
| Integration tokens | `~/.harnais/integrations/<kind>/<slug>/credentials.json` |
| Profiles | `~/.harnais/profiles/<provider>/<slug>/` |
| Wrappers | `~/.harnais/bin/` |
| Quotas | `~/.harnais/quotas.json` |
| Islands publish toggles | `~/.harnais/islands.json` |
| Usage cache | `~/.harnais/usage-cache.json` |

`quotas.json` always stays complete (Iles reads it through the installed extension, which also refreshes it when stale). `islands.json`
only lists hidden ring `type` keys; the probe and the Usage → Islands preview
filter on it. The Iles probe fetches quotas and harness sync state together
(`quotas` + `harnesses.connections[]` with per-connection `synced`, plus
`lastApply` with files) so Iles matches exactly what Harnais synced.
Harnesses = Claude, Codex, Cursor, T3. Islands = Iles rings.
Limits = live quotas. Spend = local cost/token estimates.

Provider CLI credentials stay in vendor stores. Connection tokens for Drive,
Slack, Grafana, and Atlassian are stored by Harnais (mode 0600) so every
harness can share one login. Do not commit those files.

## License

MIT. Provider names identify compatibility only.
