# Shared skills

Harnais has a dedicated Skills page. A skill is a `SKILL.md` instruction package with optional scripts, references and assets. A plugin is a container that may also include commands, agents, hooks, language servers, MCP servers or app connections.

## Using the library

1. Open Skills. Search by name or description and filter by account.
2. Open a collection, then select a skill. Artifacts & templates groups document tools and artifact templates; Slack, Atlassian, Aikido, browser automation, Sites and skill-management tools have their own collections. Readable labels and service icons replace raw identifiers. Copies with the same skill name stay grouped, and different instruction versions are identified.
3. Import a complete skill folder, import a selected installation, or create a new skill. Importing preserves the original and starts with no managed account installations.
4. Review the shared instructions and dependency warnings. Provider-specific metadata and tool requirements need adaptation before enabling the shared copy.
5. In Accounts, enable the shared copy for each desired account. Harnais links the native skill folder to one canonical source in `~/.harnais/skills/<id>/<name>`.
6. If a same-name folder already exists, choose Migrate copy. The entire file content and executable modes must match. Harnais archives the original before linking. Different or externally linked copies are never overwritten.
7. Edit the shared instructions once to update all managed installations. Existing sessions may need a provider reload.

Disable removes only the selected managed link. Other global, project or plugin copies can still be discovered. Shared removal unlinks owned installations and archives the complete canonical folder under `~/.harnais/skill-backups`. Backups also preserve instruction edits and migrated originals.

## Managing a collection

Manage opens one window with a searchable member list and Overview, Instructions, Configuration and Accounts tabs. Selecting an account installation selects its source version. Mixed Built-in and Added collections appear once with both origins shown; each member retains its own ownership and account state.

Configuration exposes controls appropriate to the source:

- Shared skills have instruction editing, account availability and scoped removal.
- Standalone Added skills have source editing and local removal. Removal archives the complete folder with a restore receipt. The view shows the registered accounts that read that path and offers Restore while the sheet remains open. Restore refuses to overwrite a new installation.
- Plugin skills use the owning plugin's existing Disable/Remove controls inline. These controls affect the whole plugin, including its other components.
- Built-in and provider-synced skills retain provider ownership and direct users to the provider's settings.

Local removal rejects stale inventory, provider-owned folders and paths outside known skill roots. It preserves supporting resources. No installed skill or provider plugin is removed automatically by collection grouping.

## Separation from Connections

Skills lists actual instruction packages, including those inside provider plugins. Provider extensions shows the package components and retains the existing scoped Disable/Remove workflow. A plugin positively identified as containing only skills, commands, agents, hooks or language servers moves out of Connections. Packages with MCP servers or app connections remain in Connections and can also appear in Skills with their skill components.

Built-in, Added and Shared remain distinct. A plugin cache record stays activation-unverified. A global skill inherited by multiple accounts is not automatically claimed as owned by Harnais.

## Availability and scope

Native managed destinations are Claude's profile `skills` folder, Codex's `CODEX_HOME/skills`, Cursor's profile `skills` folder, and OpenCode's `XDG_CONFIG_HOME/opencode/skills`. The installed Codex app-server was tested with a disposable `CODEX_HOME/skills` fixture and returned the skill in `skills/list` without running a model.

The inventory scans registered account directories, compatible global roots, Codex system skills and installed plugin skill paths. It follows linked skill folders and excludes provider trash. This is a local file inventory, not a claim that provider permissions allow invocation. It does not enumerate every repository on disk or cloud-only skills. Account policies, workspace skill precedence, cloud synchronization and plugin activation can change availability.

Cursor and OpenCode can inherit global Claude skills; Cursor can inherit global Codex skills. The Accounts view explains these overlaps and reports independent sources. Accounts pointing at the same directory necessarily share that installation. Disabling one Harnais link is not a universal provider permission denial.

Instruction token size uses roughly one token per four UTF-8 bytes. It is an estimate for the main file, not measured billing or a total including scripts, metadata and references. Providers usually load full instructions on invocation.

## Validation

720 automated checks pass, including 60 skill-library, discovery, presentation and local-removal checks. Disposable fixtures cover all seven account positions across four providers, content propagation, independent disablement, conflicts, safe migration, external replacement protection, archives, dependency warnings, path validation, plugin routing and trash exclusion. Live skills and plugin activation are not modified by the upgrade.

## Provider references

- [Codex skills](https://learn.chatgpt.com/docs/build-skills): discovery, symlink support, lazy loading and per-skill configuration.
- [Claude skills](https://code.claude.com/docs/en/skills): personal, project and plugin scopes, compatible command files and symlink behavior.
- [Cursor skills](https://cursor.com/docs/skills): discovery and skill packages.
- [Cursor compatibility paths](https://cursor.com/help/customization/skills): inherited Claude, Codex and agent skill directories.
- [OpenCode skills](https://opencode.ai/docs/skills): metadata requirements and global compatibility roots.

The native `CODEX_HOME/skills` behavior is verified against the installed CLI; current public documentation emphasizes the common `~/.agents/skills` root. Harnais uses account-specific destinations to avoid installing everything globally.

The packaged UI was checked for skill discovery, component labels, creation of a temporary disabled skill, and all seven account controls. The fixture was removed after verification. All 77 Shared connection entries remained configured without warnings.

The collection upgrade was checked in the packaged UI with 71 unique skills across seven registered accounts. Artifacts & templates contains 30 members and Slack contains eight. Checks covered member search, Claude document selection, inline plugin controls, and the local removal confirmation with inherited-account scope. The confirmation was cancelled; real skills were preserved. The inventory retained all 77 Shared connection entries with no configuration warnings.
