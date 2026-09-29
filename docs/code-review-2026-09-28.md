# Code and performance review, 28 September 2026

This review covers the Swift app, domain and infrastructure modules, CLI, Go WhatsApp helper, packaging, and regression suite. Changes target observed duplication, file boundaries, unnecessary scan work, and subprocess correctness. Existing provider configuration and service permissions remain intact.

## Changes

| Area | Finding | Change |
| --- | --- | --- |
| Process execution | Waiting for exit before reading stdout can deadlock a verbose child; writing a large stdin can also block before the timeout starts. | Poll stdin and stdout together with nonblocking descriptors and a monotonic deadline. Kill and reap timed-out children. Preserve merged stdout/stderr and exit status. Bound captured output to 64 MiB, with a configurable limit. |
| Codex JSON-RPC | Each reply reparsed all earlier output, retained consumed responses, and slept another 50 ms. | Consume complete lines once, retain only partial input and unmatched replies, and remove delivered replies. Bound partial input to 4 MiB and unmatched replies to 128. |
| Shell PATH discovery | Separate subprocess implementation had the same wait-before-drain defect. | Use the common runner while keeping stderr out of the PATH result. |
| Usage cache | Every refresh serialized the cache and wrote a backup even when nothing changed. Large files also triggered repeated full-cache checkpoints. | Write once after a changed scan. Skip serialization and writes for unchanged scans. Prune deleted files and validate account attribution before reusing events. |
| Transcript parsing | Removing the start of a Data buffer for every line caused repeated copying. A new ISO formatter was allocated for every timestamp. | Remove consumed bytes once per chunk. Reuse two date formatters behind a lock, preserving fractional and whole-second parsing. |
| Usage refresh ownership | Accounts can change while a background scan runs. | Discard stale-account results and rescan the current accounts. |
| Inventory refresh | Generation checks discarded stale results but did not prevent concurrent scans. | Run one scan at a time and repeat for the newest request if another refresh arrived. Publish only the current result. |
| Skill inventory | Account scans reread and hashed the same shared skill files; plugin roots were walked twice. | Cache file lists, parsed metadata and fingerprints within one scan. Resolve shared ownership by canonical path once. Refreshes still observe external file changes. |
| Temporary allocations | Background inventory and usage work could leave Foundation temporaries on executor threads. | Scope that work in autorelease pools. |
| Dead code | Obsolete login UI, update popover, badge, Cursor import handler, exclusion wrappers, parsing wrapper, glossary and grouping helpers had no callers. | Remove them. Keep executable entry points and protocol/NSView callbacks. Remove an unused target-path set. |

The scanner now persists at the end of a completed scan. If interrupted before that write, the previous atomic cache remains usable and changed files are rescanned next time. The old per-file checkpoints are intentionally removed.

The subprocess limits fail explicitly rather than truncating output. Normal responses in the regression and live checks stay well below those limits. The runner reaps its direct child; it does not establish a process group to terminate arbitrary descendants.

## File boundaries

- `HarnaisRuntime.swift` went from 702 lines to about 260. Provider operations, usage, settings, and connection actions are separate extensions. Public state remains read-only outside HarnaisCore.
- `UsagePageView.swift` went from 690 lines to 198. Limits, Spend and Islands rendering live in separate extensions of the same view, preserving its state and identity.
- The 630-line palette file now contains theme tokens. Buttons, fields, dialogs, settings layout and view utilities have separate files.
- The 731-line WhatsApp entry file is split into CLI/transport, daemon, message storage, tool dispatch, sending, and MCP framing. Function behavior is unchanged.
- The 2,775-line test file is split by subsystem. All original test string literals and 765 checks are preserved. The largest source or test file is now under 500 lines.

## Measurements

Release builds on this Mac. The reproducible fixture contains 6,000 events in twelve files larger than 1 MB. Both versions return all 6,000 events.

| Measurement | Before | After |
| --- | ---: | ---: |
| Cold transcript scan and cache write | 2.93 s | 0.80 s |
| Unchanged scan, median of three | 47 ms | 23 ms |
| Twenty short subprocesses | 1.10 s | 0.43 s |
| Benchmark peak resident memory | 36.6 MiB | 35.4 MiB |
| Real skill inventory, including CLI startup | 0.57 s | 0.50 s |
| Real skill inventory peak resident memory | 19.3 MiB | 20.3 MiB |

Per-scan metadata reuse trades about 1 MiB in this skill fixture for fewer reads and hashes. It is discarded at the end of the scan.

The real usage-cache comparison contained 155,546 events. Both versions matched the reference totals. Peak resident memory was approximately 345 MiB before and 329 MiB after; these single runs do not establish a sustained RAM improvement.

The app was already idle at 0% CPU before this review. After the changes, twenty consecutive one-second idle samples also reported 0%. CPU time increased by 0.01 seconds over that interval. Interaction and initial scanning naturally produce short CPU bursts.

RSS alone is misleading for this app: the original process's RSS fell from about 446 MiB to 126 MiB without a restart or code change. Physical footprint samples and workload should be compared as well. Opening charts also changes retained UI allocations. No large idle-memory reduction is claimed.

Run the fixture with:

```sh
swift run -c release HarnaisTests --benchmark-review
```

The actual usage cache can be benchmarked without modifying it:

```sh
swift run -c release HarnaisTests --benchmark-usage ~/.harnais/usage-cache.json
```

## Validation

- 784 Swift regression checks pass, including all 765 original checks.
- New cases cover output larger than pipe capacity, simultaneous large stdin/stdout, nonzero exit codes, stderr isolation, closed stdin, timeout of a child ignoring SIGTERM, output limits, fragmented JSON-RPC, out-of-order replies, and prevention of replaying consumed replies.
- Scanner cases cover unchanged-cache mtime, account reassignment, deleted transcripts, chunk boundaries, oversized lines, CRLF, final unterminated lines, and ISO date compatibility.
- WhatsApp `go test -race ./...` and `go vet ./...` pass.
- Connection inventory for all seven accounts and all 171 skill occurrences matched the pre-change CLI snapshots exactly.
- All 84 read-only MCP queries passed: twelve shared connections through seven saved account configurations. These are direct protocol checks, not model-generated tool choices. No send or upload was performed.
- The rebuilt app was inspected in Overview, Usage/Limits, Spend/Cost, Spend/Tokens, Islands, Connections, the shared Drive account view, Skills, collection configuration, Binaries, and Settings.
- Harnais Dev was packaged, its signature verified, gracefully quit, and relaunched from `dist/Harnais Dev.app`. The WhatsApp daemon reconnected using its saved session. The final startup displayed the cached overview and completed the fresh Spend report.

## Review limits and follow-ups

The source reference scan is a candidate finder, not proof that every possible dead declaration is absent. Runtime callbacks were checked before removing candidates. Existing provider-specific authentication, credential locks, configuration backups, read-only restrictions, and attachment size/path guards were preserved.

Configuration saves and some account/connection mutations still use synchronous APIs on the main actor. WhatsApp unlink can wait on a helper. Moving all mutations off that actor should use one serialized operation coordinator, with cancellation and failure-recovery tests, to avoid racing a disconnect against a save or sync. This review does not claim that those flows are nonblocking.

A prototype reused the decoded startup cache for both preview and refresh. Its app peak footprint was higher, so it was reverted. The sequential preview and refresh still decode twice; each releases its working data before the next step.

The usage cache still stores event-level JSON. Very large histories therefore retain a decoding-memory cost. Incremental storage would need migration, deduplication and recovery tests; the measurements here do not justify silently replacing the format.

The WhatsApp history handler still performs individual database writes. This review split its responsibilities and checked for races, but did not change sync semantics or run a new device-history import. Long-running leak analysis and every external provider's interactive login/removal flow are outside the validation above.
