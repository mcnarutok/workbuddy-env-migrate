#!/usr/bin/env bash
# 刷新 ChatCut MCP 的 access_token 并写回 ~/.workbuddy/mcp.json
#
#   check                        仅探测 access_token 是否已失效（不修改文件）
#   refresh                      用 refresh_token 换新 token 并写回
#   full                         refresh_token 也失效时，走完整 OAuth 授权流程
#
# access_token 有效期仅 1 小时；换机器、长时间不用后必然过期。
#
set -euo pipefail

MCP_JSON="$HOME/.workbuddy/mcp.json"
TOKEN_URL="${CHATCUT_TOKEN_URL:-https://api.chatcut.io/auth/mcp/token}"
# WorkBuddy 侧注册的 OAuth client。这是 public client_id（PKCE 公开客户端，
# 按 RFC 6749 可公开），不是凭据；refresh / full 流程必须复用同一 ID。
# 若你重新注册过自己的客户端，用 CHATCUT_CLIENT_ID 覆盖。
CLIENT_ID="${CHATCUT_CLIENT_ID:-GaDSEnZzcotEDOMZXSGoxJtPRwrRUoei}"
REDIRECT_URI="${CHATCUT_REDIRECT_URI:-http://127.0.0.1:52961/callback}"

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

# refresh_token 单独存放，权限 600，不混进 mcp.json 避免误提交
TOKEN_STORE="$HOME/.workbuddy/.chatcut-tokens"

read_refresh_token() {
  [[ -f "$TOKEN_STORE" ]] && cat "$TOKEN_STORE" || true
}

save_refresh_token() {
  umask 077
  printf '%s' "$1" >"$TOKEN_STORE"
}

read_field() {
  python3 -c "
import json,sys
d=json.load(open('$MCP_JSON'))
c=d.get('mcpServers',{}).get('chatcut',{})
print(c.get('headers',{}).get('Authorization','').replace('Bearer ','').strip())
" 2>/dev/null || true
}

# 试探当前 token 是否还能用
probe() {
  local rt
  rt="$(read_refresh_token)"
  if [ -z "$rt" ] || [ "$rt" = "__refresh_token" ]; then
    echo "[check] 未找到 refresh_token，需执行 full 重新授权"; exit 2
  fi
  # 探测 refresh 链路而非 access_token —— 判定标准是「还能不能续上新 token」
  code="$(curl -s -o /tmp/chatcut-probe.json -w '%{http_code}' \
    -X POST "$TOKEN_URL" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "grant_type=refresh_token" \
    -d "refresh_token=$rt" \
    -d "client_id=$CLIENT_ID")" || code=""
  code="${code:-unknown}"
  if [ "$code" = "200" ]; then
    echo "[check] 授权可续期（HTTP ${code}），无需动作"; exit 0
  fi
  echo "[check] refresh_token 已失效（HTTP ${code}），需执行 full 重新授权"; exit 1
}

do_refresh() {
  local rt
  rt="$(read_refresh_token)"

  if [[ -z "$rt" || "$rt" == "__refresh_token" ]]; then
    echo "[refresh] 未找到 refresh_token，改用 full 走完整授权" >&2
    exec bash "$0" full
  fi

  local resp
  resp="$(curl -s -X POST "$TOKEN_URL" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "grant_type=refresh_token" \
    -d "refresh_token=$rt" \
    -d "client_id=$CLIENT_ID")"

  if ! printf '%s' "$resp" | grep -q '"access_token"'; then
    echo "[refresh] 刷新失败，响应："
    printf '%s\n' "$resp" | head -c 600
    echo
    echo "[refresh] refresh_token 可能已作废，执行: bash $0 full"
    exit 1
  fi

  python3 -c "
import json,os,sys
resp=json.loads(sys.argv[1])
p=os.path.expanduser('~/.workbuddy/mcp.json')
d=json.load(open(p))
c=d['mcpServers']['chatcut']
c['headers']['Authorization']='Bearer '+resp['access_token']
json.dump(d,open(p,'w'),indent=2,ensure_ascii=False)
if resp.get('refresh_token'):
    store=os.path.expanduser('~/.workbuddy/.chatcut-tokens')
    fd=os.open(store,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
    os.write(fd,resp['refresh_token'].encode()); os.close(fd)
print('[refresh] 已写回', p)
print('[refresh] expires_in:', resp.get('expires_in'))
" "$resp"
}

# 完整 OAuth：注册（若需要）→ PKCE → 本地回监听 → 换 token
do_full() {
  python3 - "$TOKEN_URL" "$CLIENT_ID" "$REDIRECT_URI" <<'PY'
import base64, hashlib, http.server, json, os, secrets, socketserver, sys, urllib.parse, webbrowser, urllib.request

token_url, client_id, redirect_uri = sys.argv[1], sys.argv[2], sys.argv[3]
verifier = secrets.token_urlsafe(32)
challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()

port = int(urllib.parse.urlparse(redirect_uri).port)
captured = {}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if 'code' in q:
            captured['code'] = q['code'][0]
            self.send_response(200); self.end_headers()
            self.wfile.write(b'ChatCut authorized - you can close this tab.')
    def log_message(self, *a): pass

srv = socketserver.TCPServer(('127.0.0.1', port), H); srv.timeout = 1
auth = ('https://api.chatcut.io/auth/mcp/authorize?response_type=code'
        f'&client_id={client_id}&code_challenge={challenge}'
        f'&code_challenge_method=S256&redirect_uri={redirect_uri}'
        '&scope=openid+profile+email+offline_access&state=workbuddy')
webbrowser.open(auth)
print('[full] 已在默认浏览器打开授权页，点 Allow ...')
for _ in range(300):
    srv.handle_request()
    if 'code' in captured: break
srv.server_close()
code = captured.get('code')
if not code:
    print('[full] 超时未收到回调'); sys.exit(1)

form = {'grant_type':'authorization_code','code':code,'redirect_uri':redirect_uri,
        'client_id':client_id,'code_verifier':verifier}
req = urllib.request.Request(token_url, data=urllib.parse.urlencode(form).encode(),
                              headers={'Content-Type':'application/x-www-form-urlencoded'})
resp = json.load(urllib.request.urlopen(req))
p = os.path.expanduser('~/.workbuddy/mcp.json')
d = json.load(open(p)); c = d['mcpServers']['chatcut']
c['headers']['Authorization'] = 'Bearer ' + resp['access_token']
json.dump(d, open(p,'w'), indent=2, ensure_ascii=False)
if resp.get('refresh_token'):
    fd = os.open(os.path.expanduser('~/.workbuddy/.chatcut-tokens'),
                 os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, resp['refresh_token'].encode()); os.close(fd)
print('[full] 已写回 mcp.json，并保存 refresh_token（600）')
PY
}

case "${1:-}" in
  check)   probe ;;
  refresh) do_refresh ;;
  full)    do_full ;;
  -h | --help | "") usage ;;
  *) echo "未知子命令: $1" >&2; usage ;;
esac
