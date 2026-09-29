# Connection worklist

- [x] Group Added connections by service while preserving every account occurrence.
- [x] Use Gmail and Outlook brand icons.
- [x] Migrate Grafana identities separately and retain account-specific read-only restrictions.
- [x] Test Gmail and Outlook safe reads through all seven account configurations.
- [x] Resolve active Shared warnings with live checks. Drive now uses the stable API and passes reads on all seven accounts.
- [x] Remove superseded direct MCP entries for verified services after capability and identity checks, with backups. Keep the existing Drive connection until its replacement passes.
- [x] Complete Aikido sign-in, preserve its plugin skills, and test shared access on all accounts.
- [x] Migrate both Excalidraw servers, preserving the local canvas tools, with proper brand icons.
- [x] Finish Slack native registration and document external distribution restrictions.
- [ ] Audit usage per connection and add availability controls per connection and account.
  - Measure MCP call count, latency, response size, failures, and tool-schema size without logging private content.
  - Check what each provider exposes for actual token usage attributed to a connection. Label estimates explicitly; do not present response bytes as measured model tokens.
  - Show the measurement period, last use, and unavailable data.
  - Support enable/disable per account and optional budgets, preserving credentials and providing a reversible configuration change.
  - Separate tool discovery/context overhead from tokens spent calling and interpreting a tool.

- [x] Consolidate related Added entries under the matching Shared service, retaining account details and access to provider settings.
- [x] Create CLEYROP-owned Harnais Work, connect the main workspace, verify 27 tools and safe reads on all seven accounts, and replace the three direct Slack entries. Keep the independent Harnais app for future distribution.
- [x] Disable the duplicate Claude Slack plugin MCP in known projects while keeping its skills and commands.
- [ ] Extend duplicate-plugin MCP handling to new projects. Claude stores this switch per project; Cursor CLI currently loads only the shared Aikido and Slack servers.
- [x] Replace the blocked Google Drive preview adapter with a stable Drive API adapter; test all seven accounts and clear the failed status.
- [x] Review each Added package against provider documentation and installed metadata, with compatibility notes in Manage.
- [x] Flatten Manage navigation and distinguish cached, disabled, configured and provider-runtime entries.
- [ ] Complete Drive capability parity before retiring the retained Cursor configuration: binary Office/image extraction, workbook reading fidelity, and write permission coverage for existing files. The fallback is under Shared > Google Drive > Provider tools.

- [x] Audit provider remnants across all Shared services. Separate configured transports, retained plugin capabilities, and cached/disabled files in Manage.
- [x] Read Claude's per-project MCP disable switches independently of plugin enablement. Clear two stale shared-server switches, while preserving the Slack plugin MCP disablement.
- [x] Run an explicit read query for all 11 connections through all seven account configurations, and check each provider's native MCP inventory. Store the query and duration with the dated result.
