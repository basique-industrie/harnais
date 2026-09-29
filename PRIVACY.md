# Privacy

Harnais is local-first. It contains no analytics SDK, advertising SDK,
tracking, crash-upload service, or telemetry endpoint.

## Data processed on your Mac

Harnais creates profile directories, runs vendor CLIs for login, and reads
vendor CLI credential files or the Cursor CLI Keychain item only to label
accounts and probe quotas. Quota requests go directly to the provider that
issued the credentials, the same way that provider's own CLI does.

Drive, Gmail, Outlook, Slack, and Atlassian connection tokens, plus Grafana service-account
tokens, are stored on disk under `~/.harnais/integrations/` with mode 0600 so
Claude, Codex, Cursor, and T3 can share one login. OAuth client IDs live in
`~/.harnais/oauth-clients.json`. Harnais does not upload these files.

Provider CLI credentials are not copied into a Harnais Keychain service.
Harnais does not read the Cursor app’s `state.vscdb`.

## Removing local data

Quit Harnais, remove `~/.harnais/`, and remove wrappers from your shell PATH
if you added `~/.harnais/bin`. Vendor homes such as `~/.claude` are left in
place.

Google Drive and Gmail reuse the public Harnais Desktop registration. Outlook
uses a public Microsoft desktop registration with delegated Mail.Read. Each
service connection stores its own tokens. Requested service data is returned
to the coding tool that invoked it, whose provider may process it under its own
policies. Harnais has no central token broker or data-storage service.
