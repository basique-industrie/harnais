# Release review — 29 September 2026

## Validation

- Harnais: 894 self-tests passed; WhatsApp Go helper tests passed.
- Iles: 724 tests passed, including refresh-state completion and cancellation checks.
- Release builds and packaged resource/signature checks passed for both Dev apps.
- Live review covered seven account profiles across Claude, Codex, Cursor and OpenCode, account settings, About pages, and Overview layout.
- Public-source checks remove personal account addresses from audit notes and exclude generated Python bytecode.

## Repairs

- Harnais packaging assembles and verifies a staging bundle before replacing the installed build.
- Signed packages support Developer ID and hardened runtime for the app and both command-line helpers.
- Account actions distinguish removal from sign-in; configuration sheets identify their account.
- Overview identifies quota windows and remaining allowance; monetary totals are labeled as estimates.
- Iles uses consistent About actions and observable refresh state for loading rings.

## Public source builds

The native OAuth catalog is excluded from Git and injected only in the protected
release job. The SwiftPM resource is conditional so a clean public checkout builds
without it. Registration tests cover decoding independently of the production
catalog and refuse to substitute unrelated user credentials.

## Distribution limits

Google product OAuth remains in testing. Slack distribution to unrelated workspaces
requires approval. Microsoft organizations may restrict consent. These are service
registration limits, not resolved by signing the macOS app. Custom registrations
are supported. OpenCode does not currently provide usage reports.

Harnais is packaged for the build machine's architecture. The first signed release
is Apple silicon. Iles's release workflow builds arm64 and x86_64.

Both releases must pass Apple notarization before assets are published. The Iles
repository's protected release environment signs both products; Harnais source
and release assets are kept in their own repository.
