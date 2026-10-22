# Claude usage checks, HTTP 429, and Iles

Investigation: 2026-10-22. Iles source reviewed at
[`23098dd`](https://github.com/basique-industrie/iles/tree/23098dd3d72b2f946c1848d4ec4ae4bff8895cb3).

## What a usage-check 429 means

`GET https://api.anthropic.com/api/oauth/usage` reads subscription usage metadata.
A 429 on this GET means that **the usage check was refused**. It does not establish
that the five-hour or weekly allowance is exhausted, that inference is unavailable,
or that the login is invalid. Treat authentication errors separately. Anthropic's
[API error reference](https://platform.claude.com/docs/en/api/errors) distinguishes
401/403 from 429, but describes the public API; its inference rate tables must not
be applied as a numerical contract for this OAuth endpoint.

No authoritative requests-per-minute limit or precise throttle key for this endpoint
was established in this investigation. It may be affected by other clients of the
same login. A local per-credential lock is a coordination mechanism, not proof that
Anthropic's limit is keyed solely by access token. HTTP itself leaves identification
and counting scope to the server. See [RFC 6585 §4](https://www.rfc-editor.org/rfc/rfc6585#section-4).

`Retry-After` can contain seconds or an HTTP date. Honor a future deadline; do not
cap a long server deadline to a shorter local interval. See
[RFC 9110 §10.2.3](https://httpwg.org/specs/rfc9110.html#field.retry-after).

Two first-hand reports in Anthropic's issue tracker describe relevant failure modes:

- [claude-code #30930](https://github.com/anthropics/claude-code/issues/30930): persistent
  usage-endpoint 429s with `Retry-After: 0`, while normal Claude calls still work.
- [claude-code #31319](https://github.com/anthropics/claude-code/issues/31319): concurrent
  sessions competing for usage reads. These are user reports, not a published quota guarantee.

The [status page](https://status.claude.com/) reported all systems operational when
checked during this investigation. That does not rule out an account-specific throttle.
Do not infer a platform-wide outage from one login's usage response.

## Incident and local amplification

The local quota feed alternated between a successful OAuth reading showing 0% weekly
remaining and a CLI reading showing 1%. The CLI reading also lacked the banked-reset
metadata. Recorded feed times included 17:10:32 and 17:11:40 Europe/Paris. The two
readers were returning inconsistent snapshots; this was not a display rounding fix.

Before this change, one refresh could do all of the following:

1. Request usage with `cedar_ember=1&skip_spend=1`.
2. Immediately retry the plain usage endpoint after any non-200 response, including 429.
3. Run `claude /usage` when the API path failed, replacing the feed with that reading.
4. Issue another usage GET when the user opened the reset confirmation.

System logs contained pairs of 429 responses roughly 50–75 ms apart. This matches
the immediate retry in the code; the logs do not prove Harnais was the only caller
or the original cause of the upstream throttle.

The reset preflight error said to sign in again even for a 429. That error occurred
before the consume POST. A 429 or timeout **during the POST** remains a different,
potentially unconfirmed operation: retain its idempotency key and check before retrying.

## Harnais policy

- A usage 429 triggers neither the plain-endpoint retry nor a CLI fallback.
- The last known account limits and reset count remain visible with an error explaining
  that the refresh failed. They are display data, not authorization to spend a reset.
- Successful provider responses are reused for up to five minutes for regular refreshes.
  A reset plan accepts a response younger than sixty seconds and re-evaluates expiry
  and grant eligibility against the current time. An older response requires a new GET.
- `Retry-After` is shared by refresh and preflight. Manual clicks cannot bypass it.
  Missing, zero, invalid or past values use a five-minute wait; repeated 429s without
  a valid deadline increase that to ten, twenty, then thirty minutes. These are local
  conservative choices, not a claim about Anthropic's allowed polling rate.
- Response data, retry deadlines and consecutive-failure counts live in
  `~/.harnais/claude-usage/<credential-digest>.json`. Files are 0600, the directory is
  0700, and `flock` serializes read/request/write across processes. Bearer tokens,
  refresh tokens and request headers are never written. Treat cached usage and grant
  details as private account data; do not attach these files to public issues.
- Cache/lock failures do not trigger an uncoordinated CLI fallback. Redemption holds
  the same account lock and invalidates cached responses even if the transport fails.
- Claude's grant flags decide reset eligibility. Rounded displayed usage no longer adds
  an unconditional empty-week requirement. Anthropic says a reset can be used before
  reaching a limit in [its reset help article](https://support.claude.com/en/articles/17007452-what-is-a-limit-reset).
  Explicit provider restrictions, expiry, cooldown and confirmation still apply.

## How Iles can participate

There are three relevant paths, with different protections:

1. **Built-in Harnais provider.** Iles'
   [`HarnaisUsageProbe`](https://github.com/basique-industrie/iles/blob/23098dd3d72b2f946c1848d4ec4ae4bff8895cb3/Sources/Infrastructure/Harnais/HarnaisUsageProbe.swift)
   starts `~/.harnais/bin/harnais quotas --json` for each probe. Each invocation is a
   new process, so an in-memory singleton in the GUI cannot protect it. The shared
   Harnais state added here covers these calls when the helper is updated too.
2. **Packaged Harnais extension.** `Sources/Infrastructure/Resources/iles-extension/probe.sh`
   reads the feed and starts `harnais quotas` when it is older than 240 seconds;
   the manifest requests a 120-second poll. Its directory lock only coordinates
   extension-triggered refreshes, not GUI calls. These helper calls also use the new
   shared state. Avoid enabling this extension alongside the built-in Harnais provider.
3. **Standalone Claude provider.** Iles'
   [`ClaudeAPIUsageProbe`](https://github.com/basique-industrie/iles/blob/23098dd3d72b2f946c1848d4ec4ae4bff8895cb3/Sources/Infrastructure/Claude/ClaudeAPIUsageProbe.swift)
   already has a fifteen-minute response cache and a five-minute fallback wait for 429s;
   [`ClaudeProvider`](https://github.com/basique-industrie/iles/blob/23098dd3d72b2f946c1848d4ec4ae4bff8895cb3/Sources/Domain/Provider/Claude/ClaudeProvider.swift)
   applies a fifteen-minute background floor in API mode and suppresses fallback on 429.
   This path does **not** read Harnais' shared state. CLI mode has different behavior.

Iles' “Hide standalone providers supplied by Harnais” setting filters those providers
out of its provider list, which avoids the duplicate direct path when using Harnais.
The reviewed source defaults this setting to false. This PR does not change the user's
Iles preferences or modify Iles source.

An additional Iles limitation remains: when the Harnais JSON contains account errors
alongside retained quotas, its parser retains the values but does not expose those
per-account errors in `UsageSnapshot`. The feed's `capturedAt` describes collection,
not the last successful upstream sample for every account. Iles should eventually
carry per-account freshness/error metadata through to its rings. Do not interpret a
recent collection timestamp alone as proof that every provider check succeeded.

## Verification and recovery

Use synthetic transports and temporary directories for regression tests. The suite
covers query fallback, reset eligibility, short-lived preflight reads, cooldown parsing
and escalation, persistence across client instances, and two real child processes
sharing one request. No real reset is consumed by tests.

When investigating a live report:

1. Identify whether the failing operation is a usage GET, reset preflight, consume POST,
   or inference request. Preserve its timestamp, status and safe retry metadata.
2. Check which executable `~/.harnais/bin/harnais` invokes. Launching a rebuilt Dev GUI
   does not automatically replace a wrapper still targeting `/Applications/Harnais.app`.
   The GUI and the helper must both contain this fix.
3. Wait for the shared retry deadline. Repeated refreshes, process restarts and clearing
   the state to force retries are not recovery strategies. Other clients can still
   cause upstream throttling after Harnais has stopped requesting.
4. For an expiring reset, use Claude's supported Settings → Usage page if needed.
   A usage-check 429 is not a reason to discard credentials or consume a reset blindly.

This change reduces local request amplification. It cannot guarantee that Anthropic
will accept a request, coordinate separate machines or different OAuth tokens for the
same account, or control standalone clients that do not use Harnais.
