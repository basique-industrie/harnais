# Harnais product OAuth registrations

Harnais uses one product registration per service where supported. Every user
consents with their own account. Access and refresh tokens remain separate per
connection on the user's Mac. Personal and Work are connection labels. Coding
providers receive a local MCP adapter, never the service credentials.

## Current release status

Updated 28 September 2026.

| Service | Registration | Public availability |
| --- | --- | --- |
| Google Drive | Harnais Desktop native client created in `harnais-mcp`, owned by the maintainer; Drive, Sheets, Docs and Slides APIs enabled | Testing; Google verification still applies. Stable Drive API adapter requires no preview eligibility |
| Gmail | Same Harnais Desktop Google client; local read-only Gmail API adapter | Testing; restricted-scope review applies. No Gmail MCP preview requirement |
| Outlook | Harnais public desktop app in CLEYROP Entra, supporting organizational and personal Microsoft accounts | User consent and tenant policy apply; publisher verification not completed |
| Slack | Independent Harnais app `A0C4S9MENV9`; CLEYROP-owned Harnais Work app `A0C4SFFJURZ` | CLEYROP app has native PKCE, token rotation and MCP access enabled; shared read checks pass. Cross-workspace distribution still requires Marketplace approval |
| Atlassian | Automatic native registration during connection | User/site consent and organization policy apply |
| Grafana | No OAuth app required | User supplies their organization's service-account token |

Homepage: <https://jean-humann.github.io/harnais-site/>. Privacy and terms are
published there. Website source is in `website/` and the separate public
`jean-humann/harnais-site` repository. The macOS source is published in `basique-industrie/harnais`; user credentials
are never part of either repository.

## Desktop authentication

Native PKCE keeps login on the user's Mac. There is no Harnais token broker or
central token database. Each login generates a verifier and state; authorization
returns to `http://127.0.0.1:8788/callback`. Token requests go directly to the
service. Shared refreshes use a local cross-process lock.

The protected release build injects the git-ignored `official-oauth-clients.json`
from the `HARNAIS_NATIVE_OAUTH_CATALOG` environment secret. Source-only builds
use Advanced custom app settings. The compiled app includes this file in its Infrastructure
resource bundle. This file contains only product native-client material.
Google issues a `client_secret` field even for installed desktop clients. That
field is public installed-app material and cannot provide confidentiality. Do
not replace it with a Google Web client secret. Slack's public PKCE registration
must not contain a client secret. The catalog rejects confidential Slack records
and unclassified clients. User-supplied secrets never enter this catalog.

[Google installed applications](https://developers.google.com/identity/protocols/oauth2/native-app),
[Slack desktop PKCE](https://docs.slack.dev/authentication/using-pkce/).

## Google maintainer setup

1. Use `harnais-mcp` under the personal account. Keep the existing Web client for
   compatibility; the product uses the new **Harnais Desktop** client.
2. In Google Auth Platform, maintain Harnais branding, support contact, homepage,
   privacy policy, terms, and verified domain ownership.
3. Configure the requested scopes in Data Access. Harnais requests
   `drive.readonly`, `drive.file`, `openid`, and `email` for the local Drive API adapter
   endpoint. Do not broaden this to full `drive` access.
4. While Testing, add authorized testers. The owner is the initial tester.
   Testing is not public availability and refresh-token lifetime may be limited.
5. Complete the required verification before offering unrestricted public
   sign-in. Provide an accurate demonstration of consent, Drive usage, local
   storage, and transfer of requested results to the user's coding tool.
6. Enable Drive, Sheets, Docs and Slides APIs in the same project. Harnais uses their stable APIs; Developer Preview membership is not required. The existing `drive.file` scope allows native editing of files authorized for Harnais, without separate Sheets/Docs/Slides consent scopes.
   Default write permission is limited to files created or explicitly opened with Harnais.

[Drive API scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth),
[restricted-scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification).

## Gmail and Outlook

Gmail reuses the Google desktop client with `gmail.readonly`, `openid`, and
`email`. A local MCP adapter uses the stable Gmail REST API to list/search message
IDs, read messages, and list labels. It does not send, modify, or delete mail.
This avoids the Gmail MCP preview restriction. Drive and Gmail keep separate
connection tokens; users do not create a second Google developer app. Google
OAuth testing and restricted-scope verification still apply.

Outlook uses Microsoft Graph v1.0 through Harnais's local read-only MCP adapter.
It supports listing/searching mail and reading a message as plain text. It does
not send, edit, delete, or mark messages read. OAuth requests delegated
`Mail.Read`, `openid`, `profile`, `email`, and `offline_access`. There are no
application-wide mailbox permissions and no client secret.

The Microsoft app was created in CLEYROP's Entra directory with the user's
permission. Application ID: `85a7a8c9-f726-4f8d-b4a7-20eb481af803`.
Audience: `AzureADandPersonalMicrosoftAccount`. Public client callback:
`http://127.0.0.1:8788/callback`. The app supports users outside CLEYROP and
personal Outlook.com users; individual tenant policies may require admin consent.
No tenant-wide consent grant was made. Publisher verification remains a separate
maintainer step. Calendar and mail sending are not part of this read-only release.

[Gmail API](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list),
[Microsoft Graph mail](https://learn.microsoft.com/en-us/graph/api/user-list-messages?view=graph-rest-1.0),
[Microsoft redirect registration](https://learn.microsoft.com/en-us/entra/identity-platform/reply-url).

## Slack maintainer setup

Use the independent **Harnais** owner workspace at `harnais.slack.com`
(`T0C4Y4FN8UA`), not CLEYROP. Workspace ownership
is a durable choice. The app manifest is [slack-harnais.json](oauth-apps/slack-harnais.json).
It declares read/search user scopes, PKCE, token rotation, and the exact callback.
It has no bot or message-write scopes.

1. Create **Harnais** from that manifest in the owner workspace.
2. Verify that PKCE is enabled. This is a public desktop app; do not distribute
   the app's confidential secret. PKCE enablement cannot be reversed without
   Slack support. PKCE refresh tokens expire after 30 days.
3. Save the app's public client ID in the bundled native catalog only after the
   registration is verified. Test consent, token exchange, refresh, and MCP
   initialization in the owner workspace.
4. Add product homepage, privacy policy, support, and app descriptions. Complete
   Slack Marketplace's eligibility and review process for public distribution.
5. Marketplace eligibility currently requires at least 10 active workspaces and
   10 weekly active users, a fully tested product, and meaningful in-Slack
   functionality. Harnais does not meet those requirements yet. Do not fabricate
   usage or submit an inaccurate eligibility declaration.
6. Until Marketplace publication, the official MCP service permits this app only
   internally in its owner workspace. Enabling unlisted distribution is not a
   workaround and must not be presented as public availability.

[Slack MCP requirements](https://docs.slack.dev/ai/slack-mcp-server/),
[Slack PKCE](https://docs.slack.dev/authentication/using-pkce/),
[Marketplace guidelines](https://docs.slack.dev/slack-marketplace/slack-marketplace-app-guidelines-and-requirements/).

## Atlassian and Grafana

Atlassian's MCP service advertises dynamic native registration. Ordinary users
need no developer console. Harnais obtains its own client during sign-in, then
the user authorizes Jira/Confluence sites. This service-specific registration
step is automatic; the resulting login is still shared across coding providers.
Previously created Personal and Work custom registrations remain local and usable
through Advanced. Organization administrators may restrict MCP clients.

Grafana uses a service-account token for a specific Grafana organization, not a
universal OAuth app. The user provides their URL and token and installs
`mcp-grafana`. Harnais reuses that connection across enabled coding providers.

[Atlassian MCP](https://github.com/atlassian/atlassian-mcp-server),
[Grafana service accounts](https://grafana.com/docs/grafana/latest/administration/service-accounts/).

## Advanced custom registrations

In Add connection, expand **Advanced** and enable **Use my own OAuth app**.
Personal and Work here refer to legacy custom-registration slots only; they do
not change the connection label. Existing credentials remain intact.

Custom Google Web apps and confidential internal Slack apps use their own client
ID and secret, with the exact loopback redirect registered. The legacy
[Personal](oauth-apps/slack-personal.json) and [Work](oauth-apps/slack-work.json)
Slack manifests remain for this case. Custom remote MCP endpoints can dynamically
register where supported or use client credentials you supply.

Client credentials are stored in `~/.harnais/oauth-clients.json`; per-connection
tokens are in `~/.harnais/integrations/`. Files have owner-only permissions.
Never copy a coding provider's client ID or tokens into the product registration.
Never put tokens or confidential client secrets in chat, source, or screenshots.

## Release verification

Test with two connections to the same service and two provider processes. Verify
that each connection keeps its own credentials, simultaneous refresh happens
once, provider settings contain only executable/name arguments, and a provider's
plugin remains separate from the Harnais Shared connection. Verify packaged
resource loading as well as development builds.

Provider approval is external to Harnais. Registration, successful owner testing,
and public distribution are separate milestones. Update the UI's availability
notice only when the corresponding milestone has actually been verified.


### CLEYROP work registration

The main work connection uses internal app **Harnais Work**, app ID `A0C4SFFJURZ`, owned by CLEYROP `T01MCHX99C0`. Its public native client ID is `1726609315408.12162525640883`. It is stored separately as the local `slack:work` custom registration, with `isPublicClient: true` and no client secret. Its manifest is [slack-harnais-cleyrop.json](oauth-apps/slack-harnais-cleyrop.json).

Slack requires `settings.is_mcp_enabled: true` in addition to OAuth scopes and PKCE. Without that setting, OAuth succeeds but MCP initialization returns “App is not enabled for Slack MCP server access.” The CLEYROP app has this flag saved and verified by successful live MCP calls.

The CLEYROP custom registration requests 30 user scopes to preserve the existing Slack plugin's 27 tools, including message, reaction, canvas, list, and upload actions. The independent Harnais starter registration remains read/search only. Custom registration `scopes` are stored with its public-client setting; reconnect uses the matching app identity and scope set. Run `harnais reconnect slack` to renew this existing login without creating a second connection.
