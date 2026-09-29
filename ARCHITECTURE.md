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
file it finds (`~/.t3/userdata/settings.json`, `~/.t3/dev/userdata/settings.json`,
`$T3CODE_HOME/userdata/settings.json`, and the legacy Application Support path)
and never replaces unrelated T3 state. Imported vendor defaults
(`~/.claude`, `~/.codex`, `~/.cursor`) are skipped: T3 already owns those
slots as `claudeAgent`, `codex`, and `cursor`. A later apply also drops
`harnais_*` keys that would duplicate a native instance with the same driver
and home.

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
