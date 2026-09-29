# Security

Report a suspected vulnerability through a private security advisory at
https://github.com/basique-industrie/harnais/security/advisories/new.
Do not include account tokens, session files or private messages in public issues.

Harnais keeps service credentials locally. Shared connections expose tools to
selected coding accounts; the coding provider still controls tool approval.
Review a tool's requested action before allowing it to send or modify data.

The bundled OAuth catalog contains public native-client registration material.
It must never contain confidential web-client credentials or user tokens.
