# Connection migration, September 28, 2026

Live checks launch the exact MCP command from each registered account's configuration. They initialize the server, enumerate tools, and perform a harmless read. Reports contain status and schema fingerprints, not returned mail, files, issues, or credentials. These checks do not establish every interactive feature in every vendor application.

## Account coverage

All seven registered accounts were checked: Claude Personal, Claude Work, Codex Work 1, Codex Work 2, Codex Personal, Cursor Audit, and OpenCode Default.

| Shared connection | Live result | Migration |
| --- | --- | --- |
| Grafana Default | 7/7 datasource reads | Replaced direct entries; original server name retained |
| Grafana Ephemeral | 7/7 datasource reads | Separate token retained |
| Grafana Prod | 7/7 datasource reads | Codex Work 1 still has 43 read-only tools; other accounts have 56 tools |
| Atlassian Work | 7/7 accessible-site reads, 21 tools | Cursor direct entry replaced; provider plugin files and skills retained |
| Gmail Personal | 7/7 message-list reads, 3 tools | Stable Gmail API adapter uses personal@example.com; no preview MCP dependency |
| Outlook Work | 7/7 message-list reads, 2 tools | Microsoft Graph adapter uses work@example.com |
| Aikido Cleyrop | 7/7 issue-list reads, 4 tools | Signed in through the configured GitLab account; official server owns the Keychain login |
| Excalidraw Diagrams | 7/7 read_me calls, 5 tools | Official remote server; superseded Claude project entry removed |
| Excalidraw Canvas | 7/7 describe_scene calls, 26 tools | Existing local server preserved at version 2.0.0; superseded Cursor entry removed |
| Google Drive Personal | 7/7 stable API reads, 11 tools; private file operation checks passed | Shared adapter enabled; original Cursor fallback retained under Provider tools for documented capability differences |
| Slack Cleyrop | 7/7 emoji-search reads, 27 tools | CLEYROP-owned Harnais Work; three direct entries replaced, original `slack` server name retained |

Grafana and Aikido schemas match their original server schemas. The local Excalidraw schema matches the original 26-tool server exactly. Excalidraw's local and remote tools are different, so both modes remain distinct Shared connections. Their explicit names are `harnais-excalidraw-canvas` and `harnais-excalidraw-diagrams`.

## Warnings and duplicate entries

Google Drive now uses the stable v3 API with the existing Harnais login. All seven actual account configurations pass a file-list read. Live fixture checks passed create, metadata, permissions, read, download, search, copy, rename and trash; all three private fixtures were trashed. External sharing was tested with mocks only. The original Cursor connection remains configured because binary Office/image extraction, full workbook reading and existing-file write permissions are not yet equivalent. It is grouped under the shared service without hiding its settings.

An outdated running build could not decode the newly added service kinds, which caused its inventory to show shared wrappers under Added. The updated build recognizes them. Inventory also identifies Harnais-owned adapters when their registry entry is missing, rather than presenting them as ordinary Added connections.

Cached and deliberately disabled provider plugins are not active-connection failures. Their state remains visible. Related provider entries are accessible inside the Shared service's Manage view, avoiding repeated service rows in Added. This is a presentation grouping, not proof that a plugin is enabled or that its extra skills can be removed.

The remaining Atlassian plugin entries are a disabled Claude plugin and cached Codex files. Aikido's cached Cursor plugin may contain useful skills and rules, and its activation is not recorded by the local cache. Those files were retained. Its upstream server uses the same vendor Keychain identity as the shared server. The installed Cursor CLI lists only the shared Aikido server, not a second plugin server. Cursor GUI is not available on this Mac for a separate GUI activation check.

Claude Personal's duplicate `plugin:slack:slack` MCP is disabled in its 137 known projects, while its plugin skills and commands remain enabled. `claude mcp get plugin:slack:slack` confirms the disabled state. New projects may require the same per-project switch. Codex cached Slack packages remain intact. Cursor CLI reports only the shared `slack` server as ready.

CLEYROP Slack retains all 27 original tool names and input fields. Eight schemas differ from the older Cursor cache: Slack now declares option enums already described in the old schema, adds empty required lists, and makes several search queries optional. Write tools were enumerated but not invoked. No test sent a message, uploaded a file, created a list, or changed a canvas.

Claude's cached remote-server sign-in errors are no longer applied to a Harnais-owned local adapter with the same name. Actual shared credential and live-check failures remain visible.

## Recovery

Owner-readable backups and live check reports are under `~/.harnais/migrations/`:

- `20260928-131908-grafana`
- `20260928-131909-grafana-ephemeral`
- `20260928-131911-grafana-prod`
- `20260928-132248-atlassian`
- `20260928-134246-excalidraw`
- `20260928-134633-pause-drive-preview`
- `20260928-135518-slack-work`
- `20260928-slack-full-tools`

Restore only the relevant MCP entries from a checkpoint when newer unrelated settings exist. Do not overwrite an entire account file blindly. Dated UI check reports live in `~/.harnais/connection-checks/`.

The [worklist](connection-worklist.md) includes per-connection token/call usage and availability controls. Those usage controls are follow-up work, not implemented telemetry.

Latest backup: `~/.harnais/migrations/20260928-drive-stable-api-145016`. Tests: 627 passed. Packaged app rebuilt and relaunched. See [provider review](connection-provider-review-2026-09-28.md) for sources and remaining capability differences.
