# workbuddy-env-migrate

在机器之间搬运 WorkBuddy 本地环境——用户级 Skills、MCP 配置、身份与记忆文件，不用逐项重装。

WorkBuddy 的 **Skill**，装在 `~/.workbuddy/skills/`。当你提到换电脑、迁移环境、备份 skills、在新机器上恢复 WorkBuddy，或 ChatCut token 又报 `Unauthorized` 时，会自动加载。

[English](README.md)

## 为什么需要它

WorkBuddy **不把你的本地环境存在账号里**。云端只有资料库和历史会话；技能、`mcp.json`、身份与记忆文件、已装插件，全都是 `~/.workbuddy/` 下的普通文件。

换一台 MacBook 登录同一账号，历史会话会回来，但**一个文件都不会回来**。

迁移分两类资产，策略相反：

| 资产 | 策略 |
|---|---|
| 纯文本配置（skills / mcp.json / SOUL / MEMORY / USER / settings） | 打进 tar.gz 搬走 |
| 大体积重建物（npm `_npx`、`Developer/hyperframes-src`、`binaries`、`plugins`） | 不打包，换机后自动或手动重建 |

打包后约 1.5M，拷贝成本可忽略。

## 安装

```bash
git clone https://github.com/mcnarutok/workbuddy-env-migrate.git \
  ~/.workbuddy/skills/workbuddy-env-migrate
```

依赖 `bash`、`tar`、`python3`、`curl`（macOS / Linux 均可），无其他前置。

## 用法

```bash
# 1. 旧机：体检
bash ~/.workbuddy/skills/workbuddy-env-migrate/scripts/workbuddy-migrate.sh status

# 2. 旧机：打包（默认输出到 ~/WorkBuddy-migrate-latest）
bash ~/.workbuddy/skills/workbuddy-env-migrate/scripts/workbuddy-migrate.sh backup

# 3. 新机：先装好 WorkBuddy 并登录，再恢复
bash ~/.workbuddy/skills/workbuddy-env-migrate/scripts/workbuddy-migrate.sh restore <包> --force

# 4. 重建大体积依赖
npx -y hyperframes@0.7.60 --version

# 5. 补 ChatCut 授权（见下）
bash ~/.workbuddy/skills/workbuddy-env-migrate/scripts/chatcut-refresh.sh full
```

`restore` 不带 `--force` 时只列出将被覆盖的路径就退出，供人工确认。

### 如果 `git push` 被拦

某些网络（典型是企业 TLS 中间人）会在 TLS 握手阶段重置到 `github.com:443` 的连接，而 `api.github.com` 照常响应。此时 `git push` 报 `Recv failure: Connection reset by peer`，重认证多少次都没用。本仓库为此附了一个走 API 的发布脚本：

```bash
python3 scripts/publish-api.py
```

它用 REST API 完成同样的 blobs → tree → commit → ref 流程。需要 [`gh` CLI](https://cli.github.com/) 并已登录。`--dry-run` 只列出将要变更、不动远端。

## 凭据默认脱敏

`backup` 不会把真实 `mcp.json` 进包。流程是：先把文件复制到临时目录，把键名含 `token` / `secret` / `password` / `apiKey` / `authorization` / `credential` 的字段全部替换成 `__REDACTED__`，再打包那份副本。原始配置**不进包**。

所以迁移包里没有任何有效凭据，可以安全上传、分享、提交到仓库。代价是恢复后 MCP 会报 `Unauthorized`，属预期行为，补授权即可：

```bash
bash .../chatcut-refresh.sh refresh   # 本机存在 refresh_token 时用
bash .../chatcut-refresh.sh full      # 换机后的常规做法
```

确实要做本机冷备（且**仅此场景**）才用：

```bash
bash .../workbuddy-migrate.sh backup --with-secrets
```

这种包不要提交到任何仓库。默认行为就是为了让这个失误不必发生。

用环境变量等价开关：`WB_MIGRATE_SECRETS=1`。

覆盖四类凭据形态——漏掉任何一种，密钥就会被打进包：

| 形态 | 例子 |
|---|---|
| 键名即敏感词 | `headers.Authorization`、`env.API_KEY` |
| 值带 Bearer 前缀 | `X-Auth: "Bearer sk-..."` |
| `args` 里的参数对 | `["--api-key", "sk-..."]`、`["--api-key=sk-..."]` |
| URL 查询参数 | `url: "https://h/mcp?token=sk-..."` |

值统一替换为 `__REDACTED__`；非敏感字段（`LOG_LEVEL`、`X-Trace`、包名、URL 主体）原样保留。刻意不用高熵字符串启发式——容易误伤 URL 和哈希，而上面四类已覆盖实际 MCP 配置形态。

## 什么会被打包

`MANIFEST` 是**路径白名单**，不是文件清单。这正是它在你不断装新东西之后仍然管用的原因：

| 你新增了 | 自动进包？ | 要做什么 |
|---|---|---|
| 新装的 Skill | ✅ 会 | 放到 `~/.workbuddy/skills/` 即可，该条是**目录级**条目 |
| 新增 MCP server | ✅ 会 | 写进同一个 `~/.workbuddy/mcp.json`，脱敏自动生效 |
| Skill 里的大目录（如 job 产物） | ⚠️ 会撑大包 | 把完整相对路径加进 `EXCLUDES` |
| 清单外的其他东西 | ❌ 不会 | 每次用 `--extra <相对路径>` 追加，或写进 `MANIFEST` |
| 新的凭据文件 | ❌ 不会脱敏 | 同时登记进 `MANIFEST`（进包）和 `SECRET_FILES`（脱敏） |

```bash
# 临时追加（可重复）。按原样打包，不脱敏。
bash .../workbuddy-migrate.sh backup --extra .workbuddy/my-config
```

`--extra` 追加的内容会在 `MANIFEST.md` 里单列一段警告，所以含未脱敏内容的包会自己说明这件事。

`status` 还会列出 `~/.workbuddy/` 下**未纳入清单**的 `.json` / `.md` 文件，避免新配置被静默遗漏。WorkBuddy 自身的运行时状态（缓存、marker、各种 `*-state.json`）已列在 `IGNORE_NAMES` 里，不会刷屏。

## ChatCut token 刷新

ChatCut MCP 的 `access_token` **只活 1 小时**。换机器后必然过期，表现为 MCP 调用报 Unauthorized。

```bash
bash .../chatcut-refresh.sh check      # 探测 refresh 链路是否还能用
bash .../chatcut-refresh.sh refresh    # 用 refresh_token 换新 token
bash .../chatcut-refresh.sh full       # 完整 OAuth + PKCE，浏览器授权
```

`refresh_token` 存在 `~/.workbuddy/.chatcut-tokens`（权限 600），刻意不放进 `mcp.json`，避免误提交。

## 隐私

- 脚本**只读**清单内的路径，不上传任何东西，没有遥测。
- 不往 `$HOME` 之外写文件，恢复过程不碰原始素材。
- 打包默认脱敏凭据（见上）。
- 内置的 ChatCut `client_id` 是 OAuth 公开标识（RFC 6749 公开客户端 + PKCE），不是密钥。重新注册自己的客户端可用 `CHATCUT_CLIENT_ID` 覆盖。

漏洞披露见 [SECURITY.md](SECURITY.md)。

## 已知坑

每一个都是实打实踩出来的：

- **`mcp.json` 不能带前导点**：必须是 `~/.workbuddy/mcp.json`，写成 `.mcp.json` 服务器永远不出现。
- **macOS 自带 bash 3.2**：UTF-8 locale 下把全角 `）` 当变量名字符，`echo "HTTP $code）"` 会展开不存在的变量 `code）`。变量后紧跟全角括号时写成 `${code}`。`bash -n` 查不出来，只有真跑才炸。
- **macOS 自带 bsdtar**：exclude 通配符不跨 `/`，只能写完整相对路径，`*/node_modules` 静默失效。
- **API 主机是 `api.chatcut.io`**：拿 `chatcut.io` 注册会返回整个首页 HTML（SPA fallback），不报错但不生效。
- **`hyperframes` 必须钉 `0.7.60`**：npm `latest` 已是 0.8.x，而 cut-motion 的 job 模板钉死 0.7.60，装最新版不会走缓存复用，仍会联网重下。
- **job 必须建在 cut-motion 仓库内的 `jobs/<id>/`**：脚本用 `../../../scripts/...` 相对路径回调，放 /tmp 会 `MODULE_NOT_FOUND`。

## 结构

```
workbuddy-env-migrate/
├── SKILL.md                    路由、工作流、已知坑
├── scripts/
│   ├── workbuddy-migrate.sh    status | backup | restore
│   └── chatcut-refresh.sh      check | refresh | full
└── references/
    └── restore-runbook.md      离线恢复、验证清单、手工 OAuth
```

## 许可

MIT，见 [LICENSE](LICENSE)。
