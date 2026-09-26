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

# 打包排除项：这些目录重建成本低于拷贝成本。
#
# 关键坑：macOS 自带 bsdtar，exclude 通配符的 * 不跨 /，
# 因此必须写完整相对路径，写 */node_modules 或 node_modules 都不生效。
EXCLUDES=(
  ".workbuddy/skills/cut-motion/jobs"
)

PACK_SELF=true   # 迁移脚本自身不进包

usage() {
  cat <<'EOF'
WorkBuddy 环境迁移工具

  status                        体检当前机器
  backup   [输出目录] [--with-secrets]   打包配置（默认输出到 ~/WorkBuddy-migrate-latest）
  restore  <包路径> [--force]   解包回 $HOME

安全：backup 默认把 mcp.json 里的 token / secret / password / apiKey 等
字段替换成 __REDACTED__，迁移包可以安全上传或分享。确需带真实凭据才加
--with-secrets，且该包绝不要提交到任何代码仓库。

说明：只打包纯文本配置，不含 node_modules / npm 缓存 / managed runtime。

环境变量：WB_MIGRATE_SECRETS=1 等价于 --with-secrets。
EOF
}

# 把 JSON 里的凭据字段就地替换成占位符，返回脱敏后的内容
redact_json() {
  python3 -c "
import json,sys
src,dst = sys.argv[1], sys.argv[2]
REDACTED = sys.argv[3]
SENSITIVE = ('token','secret','password','passwd','apikey','api_key',
             'authorization','credential','private_key','access_key')
def is_secret(key, val):
    k = key.lower()
    if not isinstance(val,str) or not val or val == REDACTED:
        return False
    return any(t in k for t in SENSITIVE)
def walk(o, path=''):
    if isinstance(o, dict):
        for k,v in list(o.items()):
            if is_secret(k,v):
                o[k] = REDACTED
            else:
                walk(v, path + '.' + k)
    elif isinstance(o, list):
        for i,v in enumerate(o):
            walk(v, '%s[%d]' % (path,i))
d = json.load(open(src))
walk(d)
json.dump(d, open(dst,'w'), indent=2, ensure_ascii=False)
" "$1" "$2" "$REDACTED"
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
}

# ------------------------------------------------------------------ backup
do_backup() {
  local outdir="${1:-$HOME/WorkBuddy-migrate-latest}"
  shift || true
  local with_secrets="${WB_MIGRATE_SECRETS:-}"
  for flag in "$@"; do
    if [[ "$flag" == "--with-secrets" ]]; then with_secrets=true; fi
  done

  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local host; host="$(hostname -s)"
  mkdir -p "$outdir"

  local tgz="$outdir/workbuddy-env-$stamp-$host.tar.gz"

  local args=()
  for ex in "${EXCLUDES[@]}"; do args+=("--exclude=$ex"); done

  local mcp_rel=".workbuddy/mcp.json"
  local mcp_src="$HOME/$mcp_rel"
  local tmpdir="" tmp_arg=""
  local redacted=false

  local paths=""
  local entry path req note
  for entry in "${MANIFEST[@]}"; do
    IFS='|' read -r path req note <<<"$entry"
    [[ -e "$HOME/$path" ]] || continue
    # mcp.json 走单独通道：脱敏时打临时目录里的副本，原文件绝不进包
    if [[ "$path" == "$mcp_rel" && "$with_secrets" != "true" && -s "$mcp_src" ]]; then
      continue
    fi
    paths+="$path "
  done

  # 排除迁移脚本自身，避免把工具当文件搬走
  if [[ -e "$HOME/.workbuddy/skills/workbuddy-env-migrate" ]]; then
    args+=("--exclude=.workbuddy/skills/workbuddy-env-migrate")
  fi

  if [[ "$with_secrets" != "true" && -s "$mcp_src" ]]; then
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/wb-migrate.XXXXXX")"
    mkdir -p "$tmpdir/.workbuddy"
    if ! redact_json "$mcp_src" "$tmpdir/.workbuddy/mcp.json"; then
      echo "[backup] mcp.json 脱敏失败，为不泄露凭据已中止" >&2
      rm -rf "$tmpdir"; exit 1
    fi
    tmp_arg="-C $tmpdir .workbuddy/mcp.json"
    redacted=true
  fi

  if [[ -z "$paths" && -z "$tmp_arg" ]]; then
    echo "[backup] 没有可打包的路径，中止" >&2; exit 1
  fi

  # 多 -C 交叉打包：bsdtar 支持连续 -C，路径结构各自保留
  tar -czf "$tgz" -C "$HOME" "${args[@]}" $paths $tmp_arg
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
    if $redacted; then
      echo
      echo "## 凭据处理"
      echo
      echo "包内 \`.workbuddy/mcp.json\` 的 token / secret / password / apiKey"
      echo "类字段已替换为占位符 \`$REDACTED\`，本包不含任何真实凭据，可安全上传。"
      echo
      echo "恢复后首次调用 MCP 会报 Unauthorized，属于预期行为。补授权："
      echo
      echo '```bash'
      echo 'bash <技能目录>/scripts/chatcut-refresh.sh refresh   # 本机有 refresh_token 时用'
      echo 'bash <技能目录>/scripts/chatcut-refresh.sh full      # 换机后常规做法'
      echo '```'
      echo
      echo "注意：refresh_token 存在 \`~/.workbuddy/.chatcut-tokens\`，不在包内。"
    fi
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
