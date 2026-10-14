# Banked resets

Harnais shows an account's banked resets and can redeem one from the account page
(Usage limits → Use reset…) or from the ticket badge in Usage → Limits. A redemption spends a real credit and cannot be undone.

## Flow

1. **Plan** (read-only). Live limits and the next credit are fetched, never taken from the cache.
2. **Gate.** A reset is offered only when the weekly quota (`7d`, else the plan window) is at 0%.
   The cached limits disable the button early; the live plan decides before anything is spent.
3. **Confirm.** The dialog lists the cost, credit, limits cleared, current usage and expiry. A plan
   with a blocker offers only Close. Return does not confirm; Escape cancels.
4. **Redeem.** One request with a stored idempotency key, then a limits refresh.

## Providers

| | Codex | Claude |
|---|---|---|
| Plan | `account/rateLimits/read` → `rateLimitResetCredits` | `GET /api/oauth/usage?cedar_ember=1` → `cedar_ember` |
| Redeem | `account/rateLimitResetCredit/consume` `{idempotencyKey, creditId?}` | `POST /api/organizations/{org}/reset_rate_limits` `{program: "cedar_ember", grant_id, request_id}` |
| Outcomes | `reset`, `alreadyRedeemed`, `nothingToReset`, `noCredit` | `reset`, `already_used`, `not_limited`, `cooldown`, `ineligible`, `unavailable` |
| Target | Soonest-expiring available credit | The designated `next_grant_id` only |

Codex shapes come from `codex app-server generate-json-schema`. Claude's request was read from
Claude Code 2.1.296; it is replicated, not documented by Anthropic, so re-check it after a major
Claude Code update.

## Safety

- `ResetCreditRedeemer.plan` cannot spend. `redeem` refuses a plan that has a blocker.
- Keys live in `~/.harnais/reset-attempts.json` (0600) per account and credit. They are kept after a
  timeout or an `unavailable` answer and retired on a final one, so a retry returns "already
  redeemed" instead of spending again. If a key cannot be stored, nothing is sent.
- Claude is addressed to the organization in the account's own `.claude.json`, never another profile's.

## Testing

Tests inject every transport (`ResetCreditRedeemer(http:codexCall:claudeRequest:organizationID:)`)
and must never reach a provider. Do not call the consume endpoints against a real account.
