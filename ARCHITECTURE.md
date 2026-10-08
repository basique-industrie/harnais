# Architecture

Harnais is a Swift Package split into four production targets:

- `Domain` owns account, isolation, quota, usage, terminal preference, and
  settings models. No file I/O, no process launches.
- `Infrastructure` implements the registry, wrappers, login commands, quota
  probes, usage scan, T3 export, terminal launching, and the Iles extension
  installer.
- `HarnaisCore` is the SwiftUI shell: account editor, settings, binaries,
  usage, and the in-app login terminal (SwiftTerm).
- `Harnais` starts the windowed app. `harnais` is the CLI used by tests and
  scripting.

## Isolation

Each account is a profile. New accounts live under
`~/.harnais/profiles/<provider>/<slug>/`. Existing `~/.claude` and `~/.codex`
homes can be imported without moving them.

Claude spawn environment sets `CLAUDE_CONFIG_DIR` only. Codex sets
`CODEX_HOME` (and a T3 shadow path when requested). Cursor sets
`CURSOR_CONFIG_DIR` and `AGENT_CLI_CREDENTIAL_STORE=file` for additional
accounts.

Deleting an account drops the registry row, the PATH wrapper, and any
Harnais-created folder under `~/.harnais/profiles/`. Imported vendor homes
(`~/.claude`, `~/.codex`, `~/.cursor`) and a Codex T3-shared `~/.codex` stay.

## Quota feed

Probes run with the profile environment and write `~/.harnais/quotas.json`.
Iles reads that file through the Harnais extension in
`~/.iles/extensions/harnais`. The probe triggers `harnais quotas` in the
background when the feed goes stale, so Iles owns refresh scheduling while
Harnais owns the accounts, isolation, and probes.

## Usage

The Usage page scans Claude and Codex JSONL transcripts under each account
home and Cursor’s usage-summary API. Local scans stream line-by-line and
cache by size/mtime in `~/.harnais/usage-cache.json`.

## T3 export

Harnais generates `providerInstances` envelopes matching T3 Code's settings
schema. Apply merges extra Harnais profiles into every existing T3 settings
file it finds (`~/.t3/userdata/settings.json`, `~/.t3/dev/settings.json`,
`$T3CODE_HOME/userdata/settings.json`, and the legacy Application Support path)
and never replaces unrelated T3 state. Imported vendor defaults
(`~/.claude`, `~/.codex`, `~/.cursor`) are skipped: T3 already owns those
slots as `claudeAgent`, `codex`, and `cursor`. Apply does not add a
`harnais_*` key that would duplicate a CLI instance with the same driver
and home, and never removes existing keys, so conversations that reference
retired profiles keep working. T3-managed Codex instances
(`setupMode: "managed"`) keep their ChatGPT tokens in T3 and never count as
duplicates.

T3 Code Stable and Nightly share the bundle ID `com.t3tools.t3code` and the
same settings file. Nightly builds from 0.0.46 run Cursor through the bundled
`@cursor/sdk`, which ignores `cursor-agent`, `binaryPath` and
`CURSOR_CONFIG_DIR`; each Cursor provider in T3 signs in on its own. Harnais
detects SDK builds from `Contents/Resources/node_modules/@cursor/sdk-*`.
When every detected build uses the SDK, new Cursor entries contain their
name and stable `harnais_cursor_<slug>` ID without CLI configuration. Updates
remove only `binaryPath`, `CURSOR_CONFIG_DIR` and `AGENT_CLI_CREDENTIAL_STORE`,
preserving existing T3 credentials, enabled state, model settings and unknown
fields. SDK identities are never deduplicated by CLI home. When a CLI build is
also installed, or no build is known, Harnais retains the CLI export; a later
sync restores these settings if a CLI build is installed again.

### Through the running server

When T3 is open, `T3Exporter.sync` applies through T3's server instead of the
file. It reads `<state>/server-runtime.json`, checks the PID, and finds the app
that owns the process with `proc_pidpath`. That app's own CLI issues a short
session (`auth session issue --scope orchestration:read --scope
providers:manage --ttl 10m`). Using the running build's CLI matters because
Stable and Nightly share `~/.t3/userdata` and its database migrations. Harnais
connects to `ws://<origin>/ws?orchestrationProtocol=2` with a bearer header,
reads `server.getSettings`, merges with the same `mergedProviderInstances` the
file path uses, and sends one `server.updateSettings` upsert per changed
instance, so T3 moves sensitive environment values into its secret store. The
session is always revoked and its token is never logged or saved. If T3 is
closed, uses another state directory (a dev server), or can't issue a session,
Harnais falls back to the file transaction. A failure after the first upsert is
reported, not retried through the file.

Auto-sync re-applies one profile at a time after a rename or login when T3
already lists it, and adds a new extra profile when T3 already lists another
profile of that provider. Removing a profile switches its `harnais_*` entry
off and keeps the ID for old conversations. Syncs run one after another.
`T3SettingsWatcher` watches the settings files, `server-runtime.json` and the
relevant `<T3 home>/caches/<instanceId>.json` files (parent directory plus the
file, debounced, with content fingerprints) and refreshes placements and
statuses.

### Sign-in and status

Provider statuses come from T3's caches, or from `server.getConfig` after a
sign-in, whichever is newer. For Cursor on SDK builds, Harnais runs T3's own
flow: `provider.auth.start`, then `provider.auth.subscribe`, whose chunks are
acknowledged until a final phase arrives. It opens the HTTPS sign-in page once.
T3 locks the provider during a flow, so cancelling or timing out sends
`provider.auth.cancel` from a fresh connection with the same session. If T3 is
closed, Harnais opens the SDK build in the background first.
After a successful sync adds or re-enables a Cursor profile without an SDK
login, Harnais offers to sign in or do it later. Offers are queued one at a
time, including automatic additions; already authenticated profiles are
skipped. Signing in uses the existing T3 auth flow and never copies the
Harnais terminal login into T3.

T3-managed ChatGPT accounts (`driver: codex`, `config.setupMode: "managed"`)
are read from settings and the status cache only. Harnais does not read T3's
stored tokens, so it shows the windows T3 last reported and links to ChatGPT
usage.

## Terminal

Open in Terminal launches the account wrapper in a chosen terminal app.
Settings lists installed apps with their icons. Ghostty is the default when
it is installed; otherwise Terminal.app. The choice is stored in
`~/.harnais/settings.json`. Launch uses `open` (Launch Services), never Apple
Events, so macOS does not ask to control Ghostty or Terminal. Ghostty gets a
dedicated process with `-e` so the wrapper is that window’s command. That
process may appear as a second Dock icon until the window closes.

Official provider login stays in-app via SwiftTerm so Harnais can watch
credential files and mark the account signed in.

## Connections

Harnais owns MCP logins for Google Drive, Slack, Grafana, and Atlassian.
OAuth uses a loopback callback on `127.0.0.1:8788`. Tokens are written under
`~/.harnais/integrations/` with mode 0600. `HarnessMCPExporter` then merges
stdio `harnais mcp serve <name>` entries into Cursor `mcp.json`, Claude
`.claude.json`, Codex `config.toml`, and extra isolated profile homes. T3
inherits those files through the driver environment. Cursor IDE plugin OAuth
is a different client and is not reused.

`harnais mcp serve` is either an HTTP-to-stdio proxy (Drive, Slack,
Atlassian) or an exec of `mcp-grafana` with the stored token injected.
