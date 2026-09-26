# Security Policy

## What this tool touches

`workbuddy-migrate.sh` reads only the paths listed in its `MANIFEST` array —
`~/.workbuddy/skills`, `mcp.json`, `SOUL.md`, `MEMORY.md`, `IDENTITY.md`,
`USER.md`, `settings.json` — plus a temp copy of `mcp.json` during packaging.
It performs no network calls and sends nothing anywhere.

`chatcut-refresh.sh` talks only to `https://api.chatcut.io/auth/mcp/*`, and only
when you run `refresh` or `full` yourself.

## Credential handling

- **Packaging redacts by default.** The real `mcp.json` never enters the archive;
  a sanitized copy does. Every field whose key contains `token`, `secret`,
  `password`, `apiKey`, `authorization`, or `credential` becomes
  `__REDACTED__`. Repo contents are safe to publish.
- **`--with-secrets` exists for local cold backups only.** It writes live
  credentials into the archive. Do not commit the output.
- **The ChatCut `client_id` in the scripts is not a secret.** It is a public
  OAuth client identifier used with PKCE, as allowed by RFC 6749 §2.1. It
  cannot be used to act as you — gaining access still requires your browser
  authorization. Override it with `CHATCUT_CLIENT_ID` if you register your own.
- **`refresh_token` is stored outside `mcp.json`**, at
  `~/.workbuddy/.chatcut-tokens` with mode `600`, so an accidental
  `git add -A` cannot capture it. It is never packaged.
- If you believe a credential has leaked — for instance through a
  `--with-secrets` archive that was published — assume the ChatCut
  authorization is compromised and run `chatcut-refresh.sh full` to reauthorize.

## Reporting a vulnerability

Use GitHub's private **Report a vulnerability** on the Security tab of this
repo. Do not open a public issue for anything involving credentials.

Please include the affected command or script, your OS and shell version, and a
reproduction. You can expect an acknowledgement within a few days.
