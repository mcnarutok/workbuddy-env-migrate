# workbuddy-env-migrate

Move your WorkBuddy environment between machines — skills, MCP configuration, identity files — without reinstalling everything by hand.

A **Skill** for [WorkBuddy](https://www.workbuddy.cn). It lives in `~/.workbuddy/skills/`, and the agent picks it up automatically when you talk about switching computers, restoring an environment, backing up skills, or a ChatCut token that suddenly returns `Unauthorized`.

> [中文说明](README.zh-CN.md)

## Why this exists

WorkBuddy keeps **no** part of your local environment in your account. The cloud holds your knowledge base and conversation history; everything else — user-level Skills, `mcp.json`, identity and memory files, installed plugins — is a plain file under `~/.workbuddy/`.

Log in on a new MacBook and you get your history back, but **zero** of those files. This tool packages the text-based, version-controllable ones and ships them across.

Two asset classes, opposite strategies:

| Asset | Strategy |
|---|---|
| Text config: `skills/`, `mcp.json`, `SOUL.md`, `MEMORY.md`, `USER.md`, `settings.json` | Package into a `tar.gz` and move |
| Large rebuildables: `npm/_npx`, `Developer/hyperframes-src`, `binaries/`, `plugins/` | Leave out; rebuild on the new machine |

Result is roughly **1.5 MB** — cheaper to copy than to rebuild.

## Install

```bash
git clone https://github.com/mcnarutok/workbuddy-env-migrate.git \
  ~/.workbuddy/skills/workbuddy-env-migrate
```

Requires `bash`, `tar`, `python3`, and `curl` (macOS and Linux). Nothing else.

## Usage

```bash
# 1. On the old machine — check what's there
bash ~/.workbuddy/skills/workbuddy-env-migrate/scripts/workbuddy-migrate.sh status

# 2. On the old machine — package (defaults to ~/WorkBuddy-migrate-latest)
bash ~/.workbuddy/skills/workbuddy-env-migrate/scripts/workbuddy-migrate.sh backup

# 3. On the new machine — install WorkBuddy and sign in first, then
bash ~/.workbuddy/skills/workbuddy-env-migrate/scripts/workbuddy-migrate.sh restore <package> --force

# 4. Rebuild the large stuff
npx -y hyperframes@0.7.60 --version

# 5. Restore ChatCut authorization (see below)
bash ~/.workbuddy/skills/workbuddy-env-migrate/scripts/chatcut-refresh.sh full
```

`restore` without `--force` only lists the paths it would overwrite and exits, for human confirmation.

## Credentials are redacted by default

`backup` never puts your real `mcp.json` in the archive. The file is copied to a temp directory, where every field whose key contains `token`, `secret`, `password`, `apiKey`, `authorization`, or `credential` is replaced with `__REDACTED__`. The copy is what gets tarred.

So the archive holds no live credentials — safe to upload, share, or commit. The trade-off is that MCP calls report `Unauthorized` right after a restore, which is expected. Fix it:

```bash
bash .../chatcut-refresh.sh refresh   # if a refresh_token exists on this machine
bash .../chatcut-refresh.sh full      # the normal path on a fresh machine
```

With a truly local cold backup (and *only* then):

```bash
bash .../workbuddy-migrate.sh backup --with-secrets
```

Never commit the result. The default behaviour exists precisely to make that mistake unnecessary.

Set `WB_MIGRATE_SECRETS=1` if you prefer the environment variable over the flag.

## ChatCut token refresher

The ChatCut MCP `access_token` lives for **one hour**. Any machine change invalidates it, and the MCP surfaces that as `Unauthorized`.

```bash
bash .../chatcut-refresh.sh check      # probe whether the refresh chain still works
bash .../chatcut-refresh.sh refresh    # trade refresh_token for a new access_token
bash .../chatcut-refresh.sh full       # full OAuth + PKCE in your browser
```

`refresh_token` is stored in `~/.workbuddy/.chatcut-tokens` with mode `600`, deliberately outside `mcp.json` so a stray `git add -A` can't pick it up.

## Privacy

- The scripts **read only** the paths in their manifest. Nothing is uploaded anywhere; there is no telemetry.
- Nothing is written outside `$HOME`, and restores never touch original media.
- Default packaging redacts credentials (above).
- The bundled ChatCut `client_id` is a public OAuth identifier (RFC 6749 public client, PKCE), not a secret. Override via `CHATCUT_CLIENT_ID` if you register your own.

See [SECURITY.md](SECURITY.md) for disclosure.

## Known gotchas

Documented because each one cost real debugging time:

- **`mcp.json` must not have a leading dot.** `~/.workbuddy/mcp.json`, never `~/.workbuddy/.mcp.json` — the wrong name is the #1 reason a server never appears.
- **macOS ships bash 3.2**, which treats a full-width `）` as a variable-name character under UTF-8. `echo "HTTP $code）"` expands the nonexistent variable `code）`. Write `${code}` when a full-width bracket follows a variable. `bash -n` will not catch this; only running it will.
- **macOS ships bsdtar**, whose exclude globs don't cross `/`. Write full relative paths — `*/node_modules` and `node_modules` both silently do nothing.
- **The API host is `api.chatcut.io`.** Registering against `chatcut.io` returns a whole homepage HTML (SPA fallback): no error, no effect.
- **`hyperframes` must be pinned to `0.7.60`.** npm `latest` is 0.8.x; cut-motion's job templates pin 0.7.60, so installing latest gives you no cache reuse and a fresh download.
- **Jobs must live in the cut-motion repo's `jobs/<id>/`.** The scripts call back via `../../../scripts/...`; put a job in `/tmp` and you get `MODULE_NOT_FOUND`.

## Layout

```
workbuddy-env-migrate/
├── SKILL.md                    routing, workflow, gotchas
├── scripts/
│   ├── workbuddy-migrate.sh    status | backup | restore
│   └── chatcut-refresh.sh      check | refresh | full
└── references/
    └── restore-runbook.md      offline restore, verification checklist, manual OAuth
```

## License

MIT — see [LICENSE](LICENSE).
