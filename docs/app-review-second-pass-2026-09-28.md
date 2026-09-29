# Second app review, 28 September 2026

This pass reviewed the running macOS app, Swift domain and infrastructure code, CLI, WhatsApp helper, packaging, and regression suite. It follows the earlier [code review](code-review-2026-09-28.md) and [workflow review](ux-review-2026-09-28.md). The focus was data-loss prevention, background refresh ownership, bounded downloads, and finding shared skills from an account.

## Fixed findings

| Priority | Finding | Change and evidence |
| --- | --- | --- |
| High | A shared skill editor could silently overwrite a newer edit from another editor. | `SkillLibrary.save` accepts the editor's expected text and checks the saved file under the library lock before writing. The UI preserves the draft on conflict and offers an explicit reload with a discard confirmation. Regression checks and a live temporary fixture verified rejection, draft preservation, reload, and a successful merged save. |
| High | Drive checked its 16 MiB response limit after URLSession had buffered the whole download. A large file could therefore consume much more memory before rejection. | An opt-in streaming transport rejects oversized declared responses and cancels responses that cross the limit while arriving. It releases the partial body on failure. Drive uses this transport for its Google APIs and keeps redirect refusal and token refresh behavior. Tests cover declared and streamed oversize bodies, exact boundaries, empty bodies, errors, and timeout. |
| Medium | Quota results could publish against an account list changed during the request. | The runtime compares the captured accounts with the current accounts before publishing. If they differ, it starts another refresh and discards the old result. This follows the existing usage-refresh pattern. The change was compiled and normal refresh was checked in the app; no real account was deleted to force this race. |
| Medium | An account filter hid shared skills not yet installed for that account, preventing discovery from that view. | Shared skills remain visible. Rows show availability for the selected account and offer Manage accounts, which opens the Accounts tab. A local, uninstalled fixture reproduced the old behavior and verified the fix. Filtering Added and Built-in installations still narrows them to the selected account. |
| Low | Skill details repeatedly read and parsed SKILL.md during view evaluation, including while typing. | Metadata now loads with the selected source and refreshes after a successful save or explicit reload. The editor no longer rereads that metadata on each body evaluation. |

The download limit bounds the retained response body, not total process memory. URLSession, incoming chunks, JSON decoding, and document extraction have their own allocations. Other connectors retain their existing transport behavior.

The skill conflict check protects against edits already saved when Save begins and serializes Harnais writers. External editors do not honor Harnais's file lock, so this is not a filesystem-wide atomic compare-and-swap guarantee. Existing source backups remain in place.

## Coverage

| Area | Reviewed or exercised |
| --- | --- |
| Overview and accounts | Account status, direct launch/detail controls, account detail, account-scoped library routes, creation and removal source paths. No real account created, removed, or reauthenticated. |
| Usage | Limits, Spend, cost/token controls, Islands visibility, refresh ownership, scanner/cache behavior, and release benchmark. Pricing data was not revalidated against provider websites in this pass. |
| Connections | Shared/Added/Built-in presentation, Drive overview and seven account toggles, lifecycle routing, credential refresh locks, configuration safeguards, and live read-only MCP queries. No permissions, account selections, or saved logins changed. |
| Skills | Collections, account filtering, management tabs, shared editor conflict recovery, source loading, install/archive ownership guards, and cleanup. The test skill was never installed into a provider account. |
| Binaries and Settings | Installed CLI/status presentation, update and terminal selection paths, T3/Iles settings, local data controls, and command handling. No vendor binary updates or system setting changes performed. |
| Infrastructure | Subprocess bounds, file locks, OAuth callback and cancellation code, HTTP requests, native document tools, and WhatsApp send/document safeguards. |
| Build and code structure | Debug and release compilation, test executables, helper race checks, package signing, graceful app restart. The largest Swift source file remains below 500 lines; no further broad file splitting was justified in this pass. |

Live UI inspection used the existing design system at the app's 960-point window width. This was a workflow inspection, not a full VoiceOver, contrast, or every-window-size audit.

## Validation

- Baseline: 883 Swift checks passed.
- Updated debug suite: 893 checks passed. Ten new checks cover skill conflicts and bounded HTTP transfers.
- Updated release suite: 885 checks passed. The eight transport fixture checks use `@testable` and run in the debug configuration; the two skill checks also run in release.
- WhatsApp `go test -race ./...` and `go vet ./...` passed.
- All 84 read-only queries passed across twelve shared connections and seven registered account configurations. These direct MCP checks do not exercise a model's tool-selection behavior.
- After packaging, all seven Drive configurations passed another read query and exposed all 29 tools through the new transport.
- Connection inventory for seven accounts and all 174 discovered skill occurrences matched the pre-change snapshots exactly. The temporary shared review skill was uninstalled and excluded from provider discovery; its source, registry entry, and test backup were removed afterward.
- The live editor test confirmed that a rejected save preserved both the external file and the in-app draft. Reload then showed the external edit, and a merged save preserved both edits.
- Harnais Dev was packaged and its signature verified. The old process, 64992, quit gracefully; the new bundle launched as process 28730 and remained running.

Logs and snapshots for this run are under `/tmp/harnais-review2-*` and may be removed by macOS. The reproducible checks remain in `Tests/HarnaisTests`, `scripts/check-all-shared-connections.py`, and `scripts/probe-shared-connections.py`.

## Performance

The release fixture still processed all 6,000 events. Cold scan was 0.789 seconds. Unchanged scans were 22.6, 22.3, and 21.2 milliseconds. Twenty short subprocesses took 0.427 seconds. These results are close to the previous review's 0.80 seconds, 23 milliseconds, and 0.43 seconds; they do not establish a new speed improvement.

The targeted memory fix is early cancellation of oversized Drive downloads. No general reduction in application RAM or long-running leak freedom is claimed.

After the final Overview refresh, the last twenty one-second CPU samples were 0.0% except one 0.1% sample. Process CPU time increased by 0.01 seconds over that interval. `vmmap` then reported a 243.5 MiB physical footprint and a 666 MiB session peak. Its malloc summary showed about 38.5 MiB allocated, alongside substantial empty and fragmented regions. RSS was roughly 705 MiB before that inspection. These different accounting measures must not be treated as interchangeable. The snapshot does not establish a leak or a before/after RAM reduction; a longer allocation trace would be needed to attribute the full session peak.

## Remaining findings and limits

- Some mutations still run synchronously on the main actor, including shared connection save/sync, skill file saves, and WhatsApp unlink. A contended file lock or slow helper can stall the window. These need a serialized background mutation coordinator so moving them off the main actor does not race save, sync, and disconnect operations.
- The usage cache remains event-level JSON. Large histories still have a decoding and retained-memory cost. Replacing that storage format requires migration and recovery work beyond this review.
- The quota fix prevents publishing stale results in the app. The aggregator still writes its cache before the runtime compares account snapshots, so the on-disk cache can briefly contain the previous scan until the replacement refresh completes.
- The loopback OAuth listener limits each receive to 16 KiB but does not yet cap the accumulated header buffer or track all accepted connections for shutdown. This is a local resource-handling follow-up, not a claim of credential exposure. The new Drive response limit does not address it.
- Existing provider sessions cache tool/skill discovery. Harnais configuration and direct MCP success cannot prove that every already-running AI session has reloaded the latest tools.
- No external sign-in, destructive provider uninstall, new WhatsApp send, or cloud-document write was performed during this review. Those paths retain their existing tests and earlier live validation, rather than receiving new end-to-end coverage here.
