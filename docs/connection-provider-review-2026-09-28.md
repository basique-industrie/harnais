# Provider compatibility review, 28 September 2026

Installed in one provider does not mean exclusive to that provider. Harnais now distinguishes language servers, provider plugins, provider apps and provider runtimes. Installed accounts remain separate from compatibility claims. Cached files do not prove activation; disabled packages are not failures.

| Added package | What was checked | How Harnais presents it |
| --- | --- | --- |
| clangd-lsp | Official Anthropic plugin README; clangd backend | Language server, installed for Claude |
| pyright-lsp | Official Anthropic plugin README; Pyright backend | Language server, installed for Claude |
| rust-analyzer-lsp | Official Anthropic plugin README | Language server, installed for Claude |
| swift-lsp | Official Anthropic plugin README; SourceKit backend | Language server, installed for Claude |
| ty-lsp | Local plugin configuration and Astral editor documentation | Language server, local Claude wrapper; backend supports other editors |
| code-simplifier | Official Anthropic plugin manifest | Claude plugin with a code review/refactoring agent |
| feature-dev | Official Anthropic plugin README | Claude command and supporting agents |
| frontend-design | Official Anthropic plugin README | Claude-installed design skill; no service login |
| security-guidance | Official Anthropic plugin README | Claude hook package; no service login |
| documents | Installed OpenAI manifest and general official plugin documentation | Codex-installed document workflow |
| pdf | Installed OpenAI manifest and general official plugin documentation | Codex-installed PDF workflow |
| presentations | Installed OpenAI manifest and official plugin directory | Codex-installed slide workflow |
| spreadsheets | Installed OpenAI manifest, app dependencies and official plugin directory | Codex-installed spreadsheet workflow; app dependencies may require the host |
| template-creator | Installed OpenAI manifest and general official plugin documentation | Codex-installed template workflow |
| openai-templates | Installed OpenAI manifest; no public package-specific documentation found | Cached Codex templates, activation unverified |
| plugin-management | Installed manifest/app dependencies and general official plugin documentation | Provider app tooling, no equivalent Harnais shared adapter |
| sites | Installed manifest and app declaration; official general plugin docs, no package-specific public guide found | Cached provider app for ChatGPT Sites publishing; no Harnais adapter |
| teams | Installed Microsoft Teams app connector declaration; general official plugin documentation | Provider app connection, no equivalent Harnais shared adapter |
| computer-use | Local command points inside the provider's installed app | Provider runtime, currently disabled; do not copy its private binary configuration across providers |
| node_repl | Local command points inside ChatGPT's runtime bundle | Provider runtime; do not claim a portable service login |
| google-drive | Cursor plugin README and cached tool schemas, Google Drive API documentation | Consolidated under Shared, with the original Cursor access retained under Provider tools |

For OpenAI packages without public package-specific documentation, the installed manifest establishes what is installed, not universal exclusivity or portability. The UI links the official plugin format documentation and states that runtime dependencies need review.

## Primary references

- [Official Claude plugin repository](https://github.com/anthropics/claude-plugins-official/tree/main/plugins), including each package's README or plugin manifest.
- [Claude plugin documentation](https://code.claude.com/docs/en/plugins).
- [Astral ty editor integrations](https://docs.astral.sh/ty/editors/).
- [OpenAI plugin concepts](https://developers.openai.com/plugins/concepts/plugins) and [building plugins](https://developers.openai.com/plugins/build/plugins). These describe portable packages and host-specific capabilities, including app connections and per-plugin MCP configuration.
- [Cursor plugins](https://cursor.com/docs/plugins) and [Google Drive plugin source](https://github.com/cursor/plugins/tree/main/third_party/google-drive).
- [Drive download/export API](https://developers.google.com/workspace/drive/api/guides/manage-downloads), [scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth), and [file listing](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/list).

## Drive migration boundary

Harnais now uses the stable Drive v3 API. Its existing Google desktop registration and approved test identity remain valid; the adapter narrowly migrates the old Google preview audience. Preview membership is no longer required. Public OAuth verification remains a separate requirement.

The adapter exposes all eleven previous Cursor tool names. This is not a claim of identical capabilities. Default consent permits reading Drive and modifying files created or explicitly opened with Harnais. Binary Office files and images are downloaded rather than extracted locally. Sheets text uses PDF export; XLSX export preserves the workbook. Google-native export size limits also apply.

The original Cursor connection remains configured as a fallback until these capability differences are addressed. It is visible under Shared > Google Drive > Provider tools. Grouping changes presentation only and never deletes a working configuration.

Manage uses flat Overview/Accounts/Provider tools/Settings navigation for shared connections, and Overview/Installations for added and built-in packages. Sign-in runs inside the installation page. OAuth registration is a separate destination, not another nested Manage modal.
