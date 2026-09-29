# Shared connection audit, 28 September 2026

Checked at 2026-09-28T13:34:11Z. All 77 read queries passed. Each provider CLI also discovered all 11 shared connections in each of the seven account profiles.

Queries launched the configured MCP command with each account's environment. No model was asked to select a tool. These checks establish discovery and a successful representative read, not every write permission or every tool capability. Service response content was not saved.

| Connection | Simple query | Claude Personal | Codex Work 1 | Cursor Audit | Claude Work | Codex Work 2 | Opencode Default | Codex Personal |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| atlassian | `getAccessibleAtlassianResources` | Pass | Pass | Pass | Pass | Pass | Pass | Pass |
| grafana | `list_datasources` | Pass | Pass | Pass | Pass | Pass | Pass | Pass |
| grafana-ephemeral | `list_datasources` | Pass | Pass | Pass | Pass | Pass | Pass | Pass |
| grafana-prod | `list_datasources` | Pass | Pass | Pass | Pass | Pass | Pass | Pass |
| harnais-aikido-cleyrop | `aikido_issues_list` | Pass | Pass | Pass | Pass | Pass | Pass | Pass |
| harnais-excalidraw-canvas | `describe_scene` | Pass | Pass | Pass | Pass | Pass | Pass | Pass |
| harnais-excalidraw-diagrams | `read_me` | Pass | Pass | Pass | Pass | Pass | Pass | Pass |
| harnais-gmail-personal | `gmail_list_messages` | Pass | Pass | Pass | Pass | Pass | Pass | Pass |
| harnais-google-drive-personal | `list_recent_files` | Pass | Pass | Pass | Pass | Pass | Pass | Pass |
| harnais-outlook-work | `outlook_list_messages` | Pass | Pass | Pass | Pass | Pass | Pass | Pass |
| slack | `slack_search_emojis` | Pass | Pass | Pass | Pass | Pass | Pass | Pass |

## Provider entries

| Service | Remaining provider entries | Result |
| --- | --- | --- |
| Aikido | Cursor plugin cache and its bundled MCP definition | Cursor CLI loads only the Harnais Aikido connection. Cache activation is unverified in the GUI; plugin skills are retained. Cache records are hidden by default in Manage. |
| Google Drive | One configured Cursor fallback, plus its cached plugin | Fallback remains visible because binary Office/image extraction, spreadsheet fidelity and existing-file write access are not yet equivalent. Shared read access passes on all accounts. |
| Slack | Claude plugin with skills; plugin MCP disabled in all 137 known projects; Codex cache records | Correctly separated from the shared connection. Plugin MCP stays disabled; skills remain installed. New projects may have different switches. |
| Atlassian | Disabled Claude plugin/MCP and cached Codex package | Inactive records are separated from the shared connection. |
| Gmail, Outlook, Grafana, Excalidraw | No remaining separate entries in the scanned account inventory | Shared configurations retained. Grafana Prod still restricts Codex Work 1 to 43 read-only tools, versus 56 in other accounts. |

## Configuration repairs

Removed two stale project-level disabled-server names from Claude Personal: `slack` in `~/work/apps`, and `grafana` in the historical `~/projects/legacy` project. The separate `plugin:slack:slack` switches remain intact. Native Claude confirms shared Slack connects in the CLEYROP apps directory.

Backup: `~/.harnais/migrations/20260928-provider-audit-153103/claude.json`.

Harnais now reads per-project MCP activation independently of plugin activation. Provider tools separates configured transports, retained extensions, and cached/disabled entries. The Accounts tab shows the exact read-query label and elapsed duration for each saved check.

The first Excalidraw remote probe used the local canvas guide tool name. That probe configuration was corrected to the remote server's `read_me` tool; all seven corrected queries passed. The reusable all-connections checker chooses the correct tool for each Excalidraw mode.

## Reproduce

```sh
python3 scripts/check-all-shared-connections.py --record --output /tmp/harnais-connection-checks
swift run HarnaisTests
```

635 automated checks passed. The app is packaged as `dist/Harnais Dev.app`.

References: [Claude per-project MCP switches](https://code.claude.com/docs/en/mcp#disable-a-server-without-removing-it) and [Cursor plugin contents and activation](https://cursor.com/docs/plugins).

## Drive reader follow-up, 17:25

The Cursor Drive fallback has now been removed after the shared reader upgrade and seven successful live workbook reads. See [controls and Drive reader](connections-controls-and-drive-reader.md) for the replacement capabilities, limits, tests and migration backup. The earlier fallback entry above records the audit state at 15:34.
