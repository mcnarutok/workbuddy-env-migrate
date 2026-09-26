---
name: workbuddy-env-migrate
description: 在机器之间迁移 WorkBuddy 本地环境——用户级 Skills、MCP 配置（含 ChatCut 授权）、身份与记忆文件，并重建大体积依赖。当用户提到换电脑、换 MacBook、迁移环境、备份 skills、在新机器上恢复 WorkBuddy、ChatCut token 过期报 Unauthorized、或要求「打包/恢复环境」时使用本技能。
version: 1.0.0
metadata:
  agent_created: true
---

# WorkBuddy 环境迁移

## 前提认知

WorkBuddy 的技能、MCP 配置、身份文件**全部是本地磁盘文件，不随账号同步**。换机器后登录同一账号，云端资料库与历史会话会自动可见，但 `~/.workbuddy/skills/`、`mcp.json`、各插件不会自动出现。

迁移分两类资产，策略相反：

| 资产 | 策略 |
|---|---|
| 纯文本配置（skills / mcp.json / SOUL / MEMORY / USER / settings） | 打进 tar.gz 搬走 |
| 大体积重建物（npm `_npx`、`~/Developer/hyperframes-src`、`binaries`、`plugins`） | 不打包，换机后自动或手动重建 |

打包后约 1.5M，拷贝成本可忽略。

## 工作流

### 1. 迁移前：体检

```bash
bash ~/.workbuddy/skills/workbuddy-env-migrate/scripts/workbuddy-migrate.sh status
```

输出每项配置的存在状态与体积，并提示 ChatCut token 是否临近过期。读结果判断是否需要先补装缺失项。

### 2. 迁移前：打包

```bash
bash ~/.workbuddy/skills/workbuddy-env-migrate/scripts/workbuddy-migrate.sh backup [输出目录]
```

默认输出到 `~/WorkBuddy-migrate-latest/`，同时生成 `MANIFEST.md`（含每项「必需 / 可重建」标注）。

**默认脱敏**。打包时 `mcp.json` 不走原文件通道，而是在临时目录生成一份副本，把所有 `token` / `secret` / `password` / `apiKey` / `authorization` / `credential` 类字段替换成 `__REDACTED__` 后再进包。原始配置**不进包**。因此迁移包不含任何真实凭据，可以安全上传、分享、提交到仓库。

代价是恢复后 MCP 会报 Unauthorized，属预期行为——补授权见第 5 步。

确需带真实凭据（例如同一台机器做异地冷备）才用：

```bash
bash ... workbuddy-migrate.sh backup --with-secrets
# 或 WB_MIGRATE_SECRETS=1 ... backup
```

**这种包绝对不要提交到代码仓库。** 默认行为即为此服务的，绝大多数场景不需要这个开关。

排除项在脚本 `EXCLUDES` 里：`.workbuddy/skills/cut-motion/jobs`（测试产物）。新增大目录时往数组里加完整相对路径。

### 3. 换机后：恢复

先在**新机器**装好 WorkBuddy 并登录（云端资产此时已可用），然后：

```bash
bash <技能目录>/scripts/workbuddy-migrate.sh restore <包路径> --force
```

不带 `--force` 时脚本只列出将被覆盖的路径后退出，用于人工确认。解包后若发现凭据被脱敏，会打印补授权命令。

### 4. 换机后：重建大体积依赖

```bash
npx -y hyperframes@0.7.60 --version          # 拉回 npm 缓存，供 cut-motion 软链复用
ls ~/Developer/hyperframes-src               # 不存在则重新下载 codeload 归档包并解压
```

`~/.workbuddy/plugins/` 与 `~/.workbuddy/binaries/` 由 WorkBuddy 自行管理，无需处理。

### 5. 处理 ChatCut 授权

`access_token` 仅 1 小时有效，换机后必然过期，表现为 MCP 调用报 Unauthorized。

```bash
bash <技能目录>/scripts/chatcut-refresh.sh check      # 探测是否失效
bash <技能目录>/scripts/chatcut-refresh.sh refresh    # 用 refresh_token 换新
bash <技能目录>/scripts/chatcut-refresh.sh full       # 完整 OAuth 授权（浏览器 PKCE）
```

`refresh_token` 保存在 `~/.workbuddy/.chatcut-tokens`（权限 600）。该文件**不在迁移包内**，换机后首次 `refresh` 若提示找不到，直接改跑 `full` 重新走一遍浏览器授权——这也是换机后的常规做法。

### 6. 收尾

**必须完全退出并重启 WorkBuddy**，然后新开会话，否则新恢复的 MCP 工具不出现。校验：

```bash
ls ~/.workbuddy/skills/          # 技能是否就位
cat ~/.workbuddy/mcp.json        # 配置是否正确
```

## 已知坑

- **配置文件名不能带前导点**：必须是 `~/.workbuddy/mcp.json`，写成 `.mcp.json` 服务器永远不出现。
- **bash 3.2 与全角括号**：macOS 自带 bash 3.2 在 UTF-8 locale 下把全角 `）` 当作变量名字符，`echo "HTTP $code）"` 会被解析成展开变量 `code）`，报 `code?: unbound variable`。变量与全角括号相邻时一律写成 `${code}`，或在中间留空格。
- **macOS 自带 bsdtar**：exclude 通配符的 `*` 不跨 `/`，只能写完整相对路径，写 `*/node_modules` 无效。
- **API 主机是 `api.chatcut.io`**：用 `chatcut.io` 注册会返回一整个首页 HTML（SPA fallback），不报错但不生效。
- **版本必须精确匹配**：cut-motion 每个 job 钉死 `hyperframes@0.7.60`，npm `latest` 已是 0.8.x，装最新版不会被复用，工作流仍会联网重下。
- **job 必须建在 cut-motion 仓库内的 `jobs/<id>/`**：脚本用 `../../../scripts/...` 相对路径调仓内脚本，放 /tmp 会 MODULE_NOT_FOUND。

## 参考

`references/restore-runbook.md` 含离线恢复的分步命令、验证清单，以及 token 全失效时的手工 OAuth 步骤。需要逐条执行时读取。
