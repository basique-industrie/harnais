# Connection origins and management

Checked against provider documentation and local CLI help on 2026-09-28.

## Classification

- **Shared** means a Harnais-managed service connection. Its provider entries and login are managed from Shared.
- **Built-in** means a provider-bundled distribution or a recognized executable supplied by the desktop provider. Codex `openai-bundled` packages qualify. The desktop Computer Use and Node REPL executable locations also qualify, including their separate MCP configuration entries.
- **Added** means a separately installed or configured extension. An official publisher or marketplace does not make a plugin built-in. Claude's language servers, frontend-design, feature-dev, code-simplifier and security-guidance remain Added. Codex `openai-primary-runtime` and `openai-curated-remote` records remain Added unless there is evidence that the installation is bundled. The public documentation does not define the internal `openai-primary-runtime` marketplace as a bundled distribution.

A service appears once in the catalog. When Built-in and Added installations share a service name, the row goes under Built-in and shows “Also added.” Manage retains each installation's origin, account, configuration and controls. Grouping is for display; it does not merge credentials or establish equivalent capabilities. A disabled runtime alongside an enabled plugin is “Partly disabled.” Cached packages remain activation-unverified.

This inventory covers configured connections and plugins. It does not enumerate native tools such as shell, file editing or Claude's built-in commands.

## Added actions

Manage → Installations → select an installation → Disable/Enable or Remove.

The review shows provider, account, scope and source. Direct configuration changes keep an owner-only backup beside the settings file. JSON changes preserve unrelated values; Codex TOML changes preserve surrounding text and verify parsed equality before saving. Unsupported TOML layouts fail without writing. Removal does not revoke a service login.

| Installation | Disable / enable | Remove |
| --- | --- | --- |
| Codex plugin | Account `plugins.<id>.enabled` setting | Native `codex plugin remove` in the selected profile |
| Codex direct MCP | Account `mcp_servers.<id>.enabled` setting | Native `codex mcp remove` in the selected profile |
| Claude account plugin | Native `claude plugin disable/enable --scope user` | Native uninstall at user scope, preserving plugin data |
| Claude project plugin or plugin MCP | Instructions for `/plugin` at the actual project scope | Same scoped provider workflow |
| Claude direct MCP | Instructions for project-specific `/mcp` controls | Native `claude mcp remove --scope user` for account entries; project instructions otherwise |
| Cursor direct MCP | Account MCP disabled switch | Remove the selected configuration entry |
| Cursor plugin | Cursor Customize instructions | Cursor uninstall instructions; cache files are never deleted as a fake uninstall |
| OpenCode direct MCP | Schema-aware enabled/disabled switch | Remove the selected configuration entry |
| OpenCode plugin / provider-hosted app | Provider-specific instructions | Provider-specific instructions |

Provider handoffs show instructions and a refresh action, not a success claim. The local cache alone cannot establish whether a Cursor plugin remains active. Built-in and Shared installations are excluded from Added removal controls. Existing provider sessions may need a reload after changes.

## Validation

660 automated checks pass, including 25 lifecycle/classification checks in disposable profiles. They cover targeted removal, reenablement, preservation of neighboring settings, owner-only backups, malformed input, stale Shared adapters, account-isolated command construction, both OpenCode MCP schemas, runtime provenance and cross-origin grouping. No live integration was disabled or uninstalled to exercise these controls. In the packaged app, Computer Use appeared once under Built-in with both component states, and the Claude Disable/Remove reviews showed the selected account and canceled without changes. The before/after inventory retained all 125 entries and their states, including all 77 Shared account entries; only the two desktop runtime origins changed. The signed development bundle was relaunched and its new process verified.

## Sources

- [OpenAI plugin architecture](https://developers.openai.com/plugins/concepts/plugins): plugins package skills, MCP servers and hooks.
- [OpenAI plugin configuration](https://developers.openai.com/plugins/build/plugins): enablement and per-MCP policy are separate; managed policies can take precedence.
- [Claude plugin installation and management](https://code.claude.com/docs/en/discover-plugins): official marketplace installation, user/project/local scopes and supported management commands.
- [Claude MCP management](https://code.claude.com/docs/en/mcp): MCP connection management and scope.
- [Cursor plugin controls](https://cursor.com/docs/plugins): Customize, enablement and team-required installations.
- [OpenCode plugins](https://opencode.ai/docs/plugins/): configuration list and automatic package caching.

Installed CLI help was also checked for `codex plugin remove`, `claude plugin disable`, and `claude plugin uninstall`. Exact local bundled runtime paths are implementation evidence, not a claim made by the public documentation.
