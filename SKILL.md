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

**默认脱敏**。`SECRET_FILES` 里登记的文件（默认只有 `mcp.json`）不打原文件，而是在临时目录生成脱敏副本再进包，覆盖四类凭据形态：

| 形态 | 例子 |
|---|---|
| 键名即敏感词 | `headers.Authorization`、`env.API_KEY` |
| 值带 Bearer 前缀 | `X-Auth: "Bearer sk-..."` |
| 命令行参数成对 | `args: ["--api-key", "sk-..."]`、`["--api-key=sk-..."]` |
| URL 查询参数 | `url: "https://h/mcp?token=sk-..."` |

值统一替换为 `__REDACTED__`，非敏感字段（`LOG_LEVEL`、`X-Trace`、包名、URL 主体）原样保留。原始配置**不进包**，因此迁移包可安全上传、分享、提交。

刻意不用高熵字符串启发式：容易误伤 URL 和哈希，而上面四类已覆盖实际配置形态。

代价是恢复后 MCP 会报 Unauthorized，属预期行为——补授权见第 5 步。

确需带真实凭据（例如同一台机器做异地冷备）才用：

```bash
bash ... workbuddy-migrate.sh backup --with-secrets
# 或 WB_MIGRATE_SECRETS=1 ... backup
```

**这种包绝对不要提交到代码仓库。** 默认行为即为此服务的，绝大多数场景不需要这个开关。

#### 追加清单外的路径

```bash
bash ... backup --extra .workbuddy/my-config --extra .workbuddy/other.json
```

可重复。**这些路径原样打包，不脱敏**，MANIFEST.md 里会单列一段警告。带密钥的配置要走脱敏，得登记进 `SECRET_FILES`（见下）。

排除项在脚本 `EXCLUDES` 里：`.workbuddy/skills/cut-motion/jobs`（测试产物）。新增大目录时往数组里加完整相对路径。

### 2.5 新增内容如何进包

这是常被问到的一点，`MANIFEST` 是**路径白名单**，不是文件清单：

| 新增内容 | 是否自动进包 | 要做什么 |
|---|---|---|
| 新装的 Skill | ✅ 自动 | 放到 `~/.workbuddy/skills/` 即可，该条是**目录级**条目 |
| 新增 MCP server | ✅ 自动 | 写进同一个 `~/.workbuddy/mcp.json`，且自动脱敏 |
| Skill 里的大目录（如 job 产物） | ⚠️ 会拖大包 | 往 `EXCLUDES` 加完整相对路径 |
| 清单外的其他配置 | ❌ 不会 | 用 `--extra` 临时追加，或写进 `MANIFEST` |
| 新的凭据文件 | ❌ 不会脱敏 | 同时登记进 `MANIFEST`（进包）和 `SECRET_FILES`（脱敏） |

`status` 会列出 `~/.workbuddy/` 下**未纳入清单**的 `.json` / `.md` 文件作提示；WorkBuddy 自身的运行时状态（缓存、marker、各 `*-state.json`）在 `IGNORE_NAMES` 里，不会刷屏。

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
- **bash 3.2 与空数组**：`set -u` 下展开空数组 `"${arr[@]}"` 报 `arr[@]: unbound variable`（bash 4.4 才修）。必须写 `"${arr[@]:-}"`，且它会迭代出一个空元素，循环内要 `[[ -n "$x" ]] || continue` 掉。`${#arr[@]}` 本身安全，可用来判长度。
- **macOS 自带 bsdtar**：exclude 通配符的 `*` 不跨 `/`，只能写完整相对路径，写 `*/node_modules` 无效。
- **一条 tar 命令可接多个 `-C`**（bsdtar 与 GNU tar 都支持）：`tar -czf x.tgz -C $HOME a/b -C $tmpdir a/b` 能把不同来源的文件合并进同一个包且各自保留路径结构。这是「原文件不进包、只打脱敏副本」的落地方式——`tar --append` 追加到 gzip 档是行不通的。
- **API 主机是 `api.chatcut.io`**：用 `chatcut.io` 注册会返回一整个首页 HTML（SPA fallback），不报错但不生效。
- **版本必须精确匹配**：cut-motion 每个 job 钉死 `hyperframes@0.7.60`，npm `latest` 已是 0.8.x，装最新版不会被复用，工作流仍会联网重下。
- **job 必须建在 cut-motion 仓库内的 `jobs/<id>/`**：脚本用 `../../../scripts/...` 相对路径调仓内脚本，放 /tmp 会 MODULE_NOT_FOUND。

## 参考

`references/restore-runbook.md` 含离线恢复的分步命令、验证清单，以及 token 全失效时的手工 OAuth 步骤。需要逐条执行时读取。
