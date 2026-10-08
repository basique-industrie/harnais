# Changelog

## Unreleased

- Find T3 Code Dev settings at `~/.t3/dev/settings.json`.
- Tell Cursor users to sign in inside T3 when T3 Code runs Cursor through its SDK (Nightly 0.0.46+).
- Keep exporting Harnais Codex profiles when T3 has a T3-managed ChatGPT account at the same home.
- Update T3 Code through its running server when it's open, so T3 applies the change itself. Harnais still edits the settings file, with a backup, when T3 is closed.
- Sign in to a Cursor provider in T3 from the account's Settings tab, and see which account each T3 provider is signed in to, with a warning when it differs from the Harnais profile.
- Show ChatGPT accounts that T3 manages itself under Codex in Usage → Limits, with the limits T3 reports and a link to ChatGPT usage.
- Keep T3 in step automatically: profiles already in T3 are updated after a rename or login, new extra profiles are added when T3 already lists that provider's profiles, and removed profiles are turned off in T3. Changes made in T3 appear in Harnais right away.
- List installed T3 Code builds in Settings with their channel, version, how they handle Cursor, and which one is running.

## 0.1.3 - 2026-10-04

- Update mise-managed command-line tools with `mise upgrade --bump`, and check mise for the latest version.
- Follow the version mise currently selects for saved mise install paths, so Binaries no longer offers to switch the terminal back to an older version.
- Refresh account terminal commands after a command-line update.

## 0.1.2 - 2026-09-29

- Load app icons from the installed bundle before evaluating SwiftPM's build-machine fallback.
- Include the production executable packaging fix from 0.1.1.

## 0.1.1 - 2026-09-29

- Keep the app and command-line executable separate on case-insensitive macOS volumes so the installed app opens correctly.
- Check both development and production packaging in CI.

## 0.1.0 - 2026-09-29

- Manage isolated Claude, Codex, Cursor and OpenCode accounts, logins and terminal commands.
- View usage limits, reset countdowns and account-level banked resets.
- Share service connections and skills across selected coding accounts.
- Connect Drive, Gmail, Outlook, Slack, Grafana, Atlassian, Aikido, Excalidraw and WhatsApp.
- Read and edit Drive documents and workbooks, and transfer WhatsApp documents.
- Publish account configuration to Iles while allowing independent usage refresh.
- Show labeled allowance meters, compact account actions and estimated usage summaries on Overview.
- Organize account details into Overview and Settings, with account actions and T3 configuration.

Google product OAuth is still in testing. Slack cross-workspace distribution is
not approved, and Microsoft tenant consent policies apply. Custom registrations
remain available. OpenCode usage reporting is not yet supported. WhatsApp uses
an unofficial linked-device bridge and requires linking from your phone.
