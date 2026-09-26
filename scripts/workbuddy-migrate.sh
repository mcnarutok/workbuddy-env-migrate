#!/usr/bin/env bash
# WorkBuddy 环境迁移工具：在机器之间搬运「纯文本、可版本化、丢了要重做」的配置。
#
#   status                                 体检当前机器，输出待迁移项与缺失项
#   backup    [输出目录] [--with-secrets]  打包成 tar.gz，并生成 MANIFEST.md
#                                          默认脱敏 mcp.json 中的凭据
#   restore   <包路径> [--force]           解包回 $HOME，冲突需 --force
#
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REDACTED='__REDACTED__'

# 进包清单：<相对 $HOME 的路径>|<是否必需>|<说明>
MANIFEST=(
  ".workbuddy/skills|required|用户级 Skills（cut-motion、ChatCut 口播、html-report-to-pdf 等）"
  ".workbuddy/mcp.json|required|MCP 服务配置（token 默认脱敏，换机后需重新授权）"
  ".workbuddy/SOUL.md|required|身份与行为准则"
  ".workbuddy/MEMORY.md|optional|跨项目长期记忆"
  ".workbuddy/IDENTITY.md|optional|身份记录"
  ".workbuddy/USER.md|optional|用户画像"
  ".workbuddy/settings.json|optional|全局设置"
)

# 需要脱敏的文件：这些路径不打原文件，改为打包脱敏后的副本。
# 新增带凭据的配置文件时，除了加进 MANIFEST，还要在这里登记才会被脱敏。
SECRET_FILES=(
  ".workbuddy/mcp.json"
)

# 打包排除项：这些目录重建成本低于拷贝成本。
#
# 关键坑：macOS 自带 bsdtar，exclude 通配符的 * 不跨 /，
# 因此必须写完整相对路径，写 */node_modules 或 node_modules 都不生效。
EXCLUDES=(
  ".workbuddy/skills/cut-motion/jobs"
)

PACK_SELF=true   # 迁移脚本自身不进包

# WorkBuddy 自己管理的运行时状态与缓存：换机后由 App 重建，
# 不进迁移包，也不必在 status 里作为「清单外配置」提示（纯噪音）。
# App 升级若新增此类文件，加到这里即可保持提示干净。
IGNORE_NAMES=(
  ".connectors-marketplace.meta.json"
  ".skill-list-cache.json"
  "epoch-marker.json"
  "failover.json"
  "ioa-im-override.json"
  "last-launch.json"
  "mcp-approvals.json"
  "mcp-tool-list.json"
  "qimei-cache.json"
  "usage-log.json"
  "user-state.json"
  "workspace-state.json"
)

is_ignored_name() {
  local n="$1" x
  for x in "${IGNORE_NAMES[@]}"; do
    [[ "$n" == "$x" ]] && return 0
  done
  return 1
}

# 某个相对路径是否登记为脱敏目标
is_secret_path() {
  local p
  for p in "${SECRET_FILES[@]}"; do
    [[ "$p" == "$1" ]] && return 0
  done
  return 1
}

usage() {
  cat <<'EOF'
WorkBuddy 环境迁移工具

  status                        体检当前机器
  backup   [输出目录] [选项]     打包配置（默认输出到 ~/WorkBuddy-migrate-latest）
  restore  <包路径> [--force]   解包回 $HOME

backup 选项：
  --extra <相对路径>   追加打包 MANIFEST 之外的路径，可重复。
                       这些路径原样打包，不脱敏。
  --with-secrets      保留真实凭据（仅本机冷备用，勿提交到仓库）。

进包范围：MANIFEST 数组里的路径。注意 \`.workbuddy/skills\` 是目录级条目，
所以新装的 Skill 会自动进包；新加的 MCP server 只要写进 mcp.json 也会。

安全：默认把 SECRET_FILES 里的文件替换成脱敏副本——键名含 token / secret /
password / apiKey / authorization 的字段、\`--api-key\` 类命令行参数、URL 查询
参数中的密钥，统一替换为 __REDACTED__。原文件不进包，故迁移包可安全上传。

说明：只打包纯文本配置，不含 node_modules / npm 缓存 / managed runtime。

环境变量：WB_MIGRATE_SECRETS=1 等价于 --with-secrets。
EOF
}

# 把 JSON 里的凭据就地替换成占位符，写入目标文件。
#
# 覆盖四种实际出现过的凭据形态（漏掉任何一种都会把密钥打进包）：
#   1. 键名即敏感词          headers.Authorization / env.API_KEY
#   2. 值里带 Bearer 前缀     X-Auth: "Bearer sk-..."
#   3. 命令行参数成对出现     args: ["--api-key", "sk-..."] 或 ["--api-key=sk-..."]
#   4. URL 查询参数           url: "https://h/mcp?token=sk-..."
# 高熵启发式刻意不用：容易误伤 URL 和哈希，而上面四类已覆盖实际配置形态。
redact_json() {
  python3 - "$1" "$2" "$REDACTED" <<'PY'
import json
import sys
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

src, dst, REDACTED = sys.argv[1], sys.argv[2], sys.argv[3]
SENSITIVE = ('token', 'secret', 'password', 'passwd', 'apikey', 'api_key',
             'authorization', 'credential', 'private_key', 'access_key',
             'auth_key', 'client_secret')


def key_is_sensitive(key: str) -> bool:
    k = key.lower().replace('-', '_').replace('.', '_')
    return any(t in k for t in SENSITIVE)


def redact_url(u: str) -> str:
    """只替换 query 里的敏感参数值，保留 URL 其余部分。"""
    if '://' not in u:
        return u
    try:
        parts = urlsplit(u)
        if not parts.query:
            return u
        pairs = parse_qsl(parts.query, keep_blank_values=True)
        changed = False
        out = []
        for k, v in pairs:
            if key_is_sensitive(k) and v:
                out.append((k, REDACTED))
                changed = True
            else:
                out.append((k, v))
        if not changed:
            return u
        return urlunsplit((parts.scheme, parts.netloc, parts.path,
                           urlencode(out), parts.fragment))
    except ValueError:
        return u


def redact_args(items: list) -> list:
    """处理 ["--api-key", "v"] 与 ["--api-key=v"] 两种写法。"""
    out, expect_value = [], False
    for item in items:
        if not isinstance(item, str):
            out.append(item)
            expect_value = False
            continue
        if expect_value:
            out.append(REDACTED)
            expect_value = False
            continue
        if item.startswith('-') and '=' in item:
            flag, _, val = item.partition('=')
            if key_is_sensitive(flag.lstrip('-')) and val:
                out.append(f'{flag}={REDACTED}')
                continue
        if item.startswith('-') and key_is_sensitive(item.lstrip('-')):
            out.append(item)
            expect_value = True
            continue
        out.append(item)
    return out


def walk(node, parent_key: str = '') -> None:
    if isinstance(node, dict):
        for k, v in list(node.items()):
            if isinstance(v, str) and v and v != REDACTED:
                if key_is_sensitive(k):
                    node[k] = REDACTED
                elif v.lower().startswith('bearer ') or ' bearer ' in v.lower():
                    node[k] = REDACTED
                elif '://' in v:
                    node[k] = redact_url(v)
            elif isinstance(v, list) and k == 'args':
                node[k] = redact_args(v)
            else:
                walk(v, k)
    elif isinstance(node, list):
        for v in node:
            walk(v, parent_key)


data = json.load(open(src, encoding='utf-8'))
walk(data)
with open(dst, 'w', encoding='utf-8') as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
PY
}

# ------------------------------------------------------------------ status
do_status() {
  printf '%-38s %-10s %s\n' "路径" "状态" "备注"
  printf '%s\n' "----------------------------------------------------------------------"
  local path state note
  for entry in "${MANIFEST[@]}"; do
    IFS='|' read -r path _req note <<<"$entry"
    if [[ -e "$HOME/$path" ]]; then
      state="已存在"; note="体积 $(du -sh "$HOME/$path" 2>/dev/null | cut -f1)"
    else
      state="缺失"; note="迁移包恢复，或重装"
    fi
    printf '%-38s %-10s %s\n' "$path" "$state" "$note"
  done

  printf '\n%s\n' "不进包、需单独重建的大目录："
  printf '  %-38s %s\n' "~/.npm/_npx"      "npx -y hyperframes@0.7.60 --version"
  printf '  %-38s %s\n' "~/Developer/hyperframes-src" "重新下载 codeload 归档包并解压"
  printf '  %-38s %s\n' "~/.workbuddy/binaries" "随 WorkBuddy App 安装，无需处理"
  printf '  %-38s %s\n' "~/.workbuddy/plugins" "marketplace 首次启动自动安装"

  if [[ -f "$HOME/.workbuddy/mcp.json" ]]; then
    printf '\n%s\n' "ChatCut 授权状态："
    local tok
    tok="$(python3 -c "
import json,sys
try:
    d=json.load(open('$HOME/.workbuddy/mcp.json'))
    print(list(d.get('mcpServers',{}).keys()))
except Exception:
    print('(mcp.json 无法解析)')
")"
    printf '  MCP servers: %s\n' "$tok"
    printf '  access_token 仅 1 小时有效，超期需执行 chatcut-refresh\n'
  fi

  # 清单外的配置：提醒但不动手，避免新增项被静默漏掉
  local unlisted=() f rel known entry path
  while IFS= read -r f; do
    rel="${f#"$HOME"/}"
    is_secret_path "$rel" && continue
    is_ignored_name "$(basename "$rel")" && continue
    known=false
    for entry in "${MANIFEST[@]}"; do
      IFS='|' read -r path _req _note <<<"$entry"
      if [[ "$rel" == "$path" || "$rel" == "$path"/* ]]; then known=true; break; fi
    done
    $known || unlisted+=("$rel")
  done < <(find "$HOME/.workbuddy" -maxdepth 1 -type f \( -name '*.json' -o -name '*.md' \) 2>/dev/null | sort)

  if [[ ${#unlisted[@]} -gt 0 ]]; then
    printf '\n%s\n' "清单外的配置（不会被备份，需要时用 --extra 追加或写进 MANIFEST）："
    for f in "${unlisted[@]:-}"; do
      [[ -n "$f" ]] && printf '  %-38s %s\n' "$f" "未纳入"
    done
  fi
}

# ------------------------------------------------------------------ backup
do_backup() {
  local outdir="${1:-$HOME/WorkBuddy-migrate-latest}"
  shift || true

  local with_secrets="${WB_MIGRATE_SECRETS:-}"
  local extras=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-secrets) with_secrets=true; shift ;;
      --extra)        extras+=("${2:-}"); shift 2 ;;
      *)              shift ;;
    esac
  done

  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local host; host="$(hostname -s)"
  mkdir -p "$outdir"

  local tgz="$outdir/workbuddy-env-$stamp-$host.tar.gz"

  local args=()
  for ex in "${EXCLUDES[@]}"; do args+=("--exclude=$ex"); done

  local tmpdir="" secret_paths="" redacted=false

  local paths=""
  local entry path req note
  for entry in "${MANIFEST[@]}"; do
    IFS='|' read -r path req note <<<"$entry"
    [[ -e "$HOME/$path" ]] || continue
    # 登记在 SECRET_FILES 里的文件走脱敏通道：原文件绝不进包
    if [[ "$with_secrets" != "true" ]] && is_secret_path "$path" && [[ -s "$HOME/$path" ]]; then
      continue
    fi
    paths+="$path "
  done

  # --extra 追加路径。注意：这些是原样打包，不经过脱敏。
  local extra_paths="" extra_note=""
  local ex
  # bash 3.2 下空数组的 "${a[@]}" 会报 unbound variable（4.4 才修），
  # 必须用 "${a[@]:-}"；空数组时会迭代出一个空元素，故下面 continue 掉
  for ex in "${extras[@]:-}"; do
    [[ -n "$ex" ]] || continue
    if [[ -e "$HOME/$ex" ]]; then
      extra_paths+="$ex "
      extra_note+="$ex "
    elif [[ -e "$ex" ]]; then
      echo "[backup] --extra 只支持 \$HOME 下的相对路径，已跳过: $ex" >&2
    else
      echo "[backup] --extra 路径不存在，已跳过: $ex" >&2
    fi
  done

  # 排除迁移脚本自身，避免把工具当文件搬走
  if [[ -e "$HOME/.workbuddy/skills/workbuddy-env-migrate" ]]; then
    args+=("--exclude=.workbuddy/skills/workbuddy-env-migrate")
  fi

  # 脱敏通道：把 SECRET_FILES 逐个复制成脱敏副本到临时目录
  if [[ "$with_secrets" != "true" ]]; then
    for path in "${SECRET_FILES[@]}"; do
      [[ -s "$HOME/$path" ]] || continue
      [[ -n "$tmpdir" ]] || tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/wb-migrate.XXXXXX")"
      mkdir -p "$tmpdir/$(dirname "$path")"
      if ! redact_json "$HOME/$path" "$tmpdir/$path"; then
        echo "[backup] $path 脱敏失败，为不泄露凭据已中止" >&2
        rm -rf "$tmpdir"; exit 1
      fi
      secret_paths+="$path "
      redacted=true
    done
  fi

  if [[ -z "$paths$extra_paths$secret_paths" ]]; then
    echo "[backup] 没有可打包的路径，中止" >&2; exit 1
  fi

  local tmp_arg=""
  [[ -n "$tmpdir" ]] && tmp_arg="-C $tmpdir $secret_paths"

  # 多 -C 交叉打包：bsdtar 支持连续 -C，路径结构各自保留
  tar -czf "$tgz" -C "$HOME" "${args[@]}" $paths $extra_paths $tmp_arg
  [[ -n "$tmpdir" ]] && rm -rf "$tmpdir"

  {
    echo "# WorkBuddy 环境迁移包"
    echo
    echo "- 打包时间: $(date '+%F %T')"
    echo "- 来源机器: $host"
    echo "- 包文件:   \`workbuddy-env-$stamp-$host.tar.gz\`"
    echo "- 体积:     $(du -h "$tgz" | cut -f1)"
    echo
    echo "| 路径 | 必需 | 说明 |"
    echo "|---|---|---|"
    for entry in "${MANIFEST[@]}"; do
      IFS='|' read -r path req note <<<"$entry"
      if [[ -e "$HOME/$path" ]]; then
        echo "| \`$path\` | $req | $note |"
      else
        echo "| \`$path\` | — | 本机未安装 |"
      fi
    done
    if [[ -n "$extra_note" ]]; then
      echo
      echo "## 额外打包项（\`--extra\`）"
      echo
      echo "\`\`\`"
      printf '%s\n' $extra_note
      echo "\`\`\`"
      echo
      echo "**这些路径按原样打包，未经脱敏。** 里面若有密钥，包就不能外传。"
    fi
    if $redacted; then
      echo
      echo "## 凭据处理"
      echo
      echo "以下文件不打原文件，包内是脱敏副本。键名含 token / secret /"
      echo "password / apiKey / authorization / credential 的字段、以及"
      echo "\`--api-key\` 类命令行参数和 URL 查询参数中的密钥，"
      echo "均已替换为占位符 \`$REDACTED\`："
      echo
      for path in $secret_paths; do
        echo "- \`$path\`"
      done
      echo
      echo "本包不含任何真实凭据，可安全上传。恢复后首次调用 MCP 会报"
      echo "Unauthorized，属于预期行为。补授权："
      echo
      echo '```bash'
      echo 'bash <技能目录>/scripts/chatcut-refresh.sh refresh   # 本机有 refresh_token 时用'
      echo 'bash <技能目录>/scripts/chatcut-refresh.sh full      # 换机后常规做法'
      echo '```'
      echo
      echo "注意：refresh_token 存在 \`~/.workbuddy/.chatcut-tokens\`，不在包内。"
    fi
    echo
    echo "## 新增内容怎么进包"
    echo
    echo "- **新装的 Skill**：放在 \`~/.workbuddy/skills/\` 下即自动纳入，无需改动。"
    echo "- **新增的 MCP server**：写进 \`~/.workbuddy/mcp.json\` 即自动纳入并脱敏。"
    echo "- **清单外的其他配置**：临时用 \`--extra <相对路径>\` 追加，或写进脚本的 \`MANIFEST\` 数组。"
    echo "- **新增的凭据文件**：除了加进 \`MANIFEST\`，还要登记进 \`SECRET_FILES\` 才会被脱敏。"
    echo
    echo "## 不在包内（换机后重建）"
    echo
    echo "| 目录 | 体积 | 重建方式 |"
    echo "|---|---|---|"
    echo "| ~/.npm/_npx | ~614M | 执行 \`npx -y hyperframes@0.7.60 --version\` 自动拉取 |"
    echo "| ~/Developer/hyperframes-src | 226M | 重新下载 codeload 归档包并解压 |"
    echo "| ~/.workbuddy/binaries | 469M | WorkBuddy App 安装时自带 |"
    echo "| ~/.workbuddy/plugins | 231M | marketplace 首次启动自动安装 |"
  } >"$outdir/MANIFEST.md"

  echo "[backup] 包: $tgz"
  echo "[backup] 清单: $outdir/MANIFEST.md"
  echo "[backup] 下一步：把 $tgz 拷到新机器，执行 restore"
}

# ------------------------------------------------------------------ restore
do_restore() {
  local tgz="$1"; shift || true
  local force=false
  for flag in "$@"; do
    [[ "$flag" == "--force" ]] && force=true
  done

  if [[ ! -f "$tgz" ]]; then echo "[restore] 包不存在: $tgz" >&2; exit 1; fi

  if [[ "$force" != true ]]; then
    echo "[restore] 即将覆盖 \$HOME 下的以下路径："
    tar -tzf "$tgz" | sed 's/^/          /'
    echo
    echo "[restore] 确认请追加 --force（或加 --force 自动化场景）"
    exit 0
  fi

  tar -xzf "$tgz" -C "$HOME"
  echo "[restore] 解包完成 -> $HOME"
  echo "[restore] 目标机器: $(hostname -s)"

  # 包内 mcp.json 是否被脱敏过：是则必须重新授权才能用 MCP
  if [[ -f "$HOME/.workbuddy/mcp.json" ]] && grep -q "$REDACTED" "$HOME/.workbuddy/mcp.json" 2>/dev/null; then
    echo
    echo "[restore] 检测到 mcp.json 中的凭据已被脱敏，MCP 调用会报 Unauthorized。"
    echo "[restore] 补授权：bash <技能目录>/scripts/chatcut-refresh.sh refresh"
    echo "[restore] 若无 refresh_token（换机首次）则跑：bash <技能目录>/scripts/chatcut-refresh.sh full"
  fi
}

case "${1:-}" in
  status)  shift; do_status ;;
  backup)  shift; do_backup "$@" ;;
  restore) shift; do_restore "$@" ;;
  -h | --help | "") usage ;;
  *) echo "未知子命令: $1" >&2; usage ;;
esac
