# Diagnosis and recovery

Account health brings together CLI availability, local sign-in data, isolated
command routing and PATH, T3 profile settings and identity, usage freshness,
and local connection configuration. Checks older than 15 minutes are marked
unverified. Unavailable usage does not imply an expired login. Connection
configuration checks do not establish that remote services are reachable.

Use **Check accounts** for fresh account and usage probes. Open an account to
repair sign-in, or repair an out-of-date account command directly from Health.
**Copy report** excludes account names, emails, local paths, credentials and raw
provider messages. `harnais doctor --json` produces the same report format from
local files without starting sign-in or requesting usage from providers.

## Preview and history

Manual T3 sync opens a preview. It shows the destination and managed fields;
applying refuses changed accounts, changed settings or a changed destination set.
Automatic updates continue to sync existing profiles and record their changes.
The latest 100 activity records are stored in `~/.harnais/t3-sync-history.json`
with owner-only permissions. Older releases' syncs are not reconstructed.

The CLI also supports `harnais t3-preview`, `harnais t3-history` and
`harnais t3-undo <history-id>`. Undo prints a preview unless `--apply` is passed.
`harnais t3-apply` uses the same validated server/file path as the app.

Only Harnais-managed names, colors, enabled flags, CLI/home/shadow paths and
recognized non-sensitive isolation environment entries can be retained for
undo. Secrets, model choices and arbitrary environment values are excluded.
A sync that changes additional values remains visible but is not undoable.

## Undo

Choose **Preview undo** on an applied entry, review the changes, then apply.
Undo compares the current values of every touched field with the saved result.
It refuses conflicts and preserves unrelated changes, credentials and model
settings. An added profile is disabled, retaining its ID for existing T3
conversations. Undo changes T3 configuration; it does not undo edits to the
Harnais account registry, revoke sign-in or disconnect shared services. A later
Harnais account edit can sync that profile again.

Live updates use T3's server API and verify its reply. Closed-app updates use
atomic file replacement and retain protected backups. T3 does not expose a
compare-and-swap revision for these APIs: avoid editing the same provider in T3
while a sync or undo is in progress. Multiple destinations are recorded separately;
a live-server failure can leave earlier destinations applied. Failed/interrupted
operations are shown without an automatic undo action. Re-open T3, inspect its
settings and preview a fresh sync. Never restore an entire backup over newer
settings just to reverse one field.
