# 离线恢复手册

供换机后逐条执行，或迁移包与技能目录都不在手边时手工重做。

## A. 快速路径（迁移包可用）

假设迁移包在 `/path/to/workbuddy-env-20260926-<hostname>.tar.gz`，技能目录在 `~/.workbuddy/skills/workbuddy-env-migrate/`。

```bash
# 1. 解包
bash ~/.workbuddy/skills/workbuddy-env-migrate/scripts/workbuddy-migrate.sh restore <包> --force

# 2. 拉回 npm 运行时（cut-motion 依赖，走 npx 缓存复用）
npx -y hyperframes@0.7.60 --version

# 3. 找回 HyperFrames 源码（迁移包不含）
ls ~/Developer/hyperframes-src || echo "需按 B 段重下"

# 4. ChatCut 授权
bash ~/.workbuddy/skills/workbuddy-env-migrate/scripts/chatcut-refresh.sh refresh \
  || bash ~/.workbuddy/skills/workbuddy-env-migrate/scripts/chatcut-refresh.sh full

# 5. 重启 WorkBuddy，新开会话
```

## B. 手工重下 HyperFrames 源码

`git clone` 走 github 协议常被 SSL 拦（LibreSSL SSL_ERROR_SYSCALL）。改用 codeload 归档包：

```bash
mkdir -p ~/Developer/hyperframes-src
curl -sSL -o /tmp/hyperframes-src.tgz \
  https://codeload.github.com/heygen-com/hyperframes/tar.gz/refs/heads/main
tar -xzf /tmp/hyperframes-src.tgz -C ~/Developer/hyperframes-src --strip-components=1
rm -f /tmp/hyperframes-src.tgz
du -sh ~/Developer/hyperframes-src     # 预期 226M
```

源码目录不含 `.git`，后续升级需重新拉包，不能 `git pull`。

## C. 验证清单

逐条确认，任一失败先解决再继续：

| 项 | 命令 | 预期 |
|---|---|---|
| 技能就位 | `ls ~/.workbuddy/skills/` | 列出全部技能目录 |
| MCP 配置 | `python3 -c "import json;print(list(json.load(open('$HOME/.workbuddy/mcp.json'))['mcpServers']))"` | 含 `chatcut` |
| ChatCut token | `bash .../chatcut-refresh.sh check` | 输出「有效」 |
| HyperFrames CLI | `npx -y hyperframes@0.7.60 --version` | `0.7.60` |
| 视频工具链 | `ffmpeg -version \| head -1` | 含 libx264 |
| 迁移脚本自身 | `bash .../workbuddy-migrate.sh status` | 各配置均「已存在」 |

## D. token 全失效时的手工 OAuth

前两条命令都不通（refresh_token 也被清除）时，重走一遍完整授权：

```bash
# 1. 注册客户端（返回 JSON 里的 client_id）
curl -s -X POST https://api.chatcut.io/auth/mcp/register \
  -H "Content-Type: application/json" \
  -d '{"client_name":"workbuddy",
       "redirect_uris":["http://127.0.0.1:52961/callback"],
       "grant_types":["authorization_code","refresh_token"],
       "response_types":["code"],
       "token_endpoint_auth_method":"none",
       "scope":"openid profile email offline_access"}'

# 2. 本地起回调监听并打开授权页（PKCE）
python3 - <<'PY'
import base64,hashlib,http.server,json,os,socketserver,secrets,urllib.parse,webbrowser,urllib.request
cid="上一步拿到的 client_id"
v=secrets.token_urlsafe(32)
c=base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b'=').decode()
cap={}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q=urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if 'code' in q:
            cap['code']=q['code'][0]
            self.send_response(200);self.end_headers()
            self.wfile.write(b'authorized')
    def log_message(self,*a): pass
s=socketserver.TCPServer(('127.0.0.1',52961),H);s.timeout=1
webbrowser.open(f'https://api.chatcut.io/auth/mcp/authorize?response_type=code'
  f'&client_id={cid}&code_challenge={c}&code_challenge_method=S256'
  '&redirect_uri=http://127.0.0.1:52961/callback'
  '&scope=openid+profile+email+offline_access&state=workbuddy')
for _ in range(300):
    s.handle_request()
    if 'code' in cap: break
s.server_close()
form={'grant_type':'authorization_code','code':cap['code'],
      'redirect_uri':'http://127.0.0.1:52961/callback',
      'client_id':cid,'code_verifier':v}
req=urllib.request.Request('https://api.chatcut.io/auth/mcp/token',
  data=urllib.parse.urlencode(form).encode(),
  headers={'Content-Type':'application/x-www-form-urlencoded'})
resp=json.load(urllib.request.urlopen(req))
fd=os.open(os.path.expanduser('~/.workbuddy/.chatcut-tokens'),
           os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
os.write(fd,resp['refresh_token'].encode());os.close(fd)
print('access_token:',resp['access_token'])
PY

# 3. 把打印出的 access_token 写进 mcp.json
```

## E. 迁移包该不该包含的东西

判定原则：**重建成本 < 拷贝成本的不进包**。

| 目录 | 体积 | 判定 |
|---|---|---|
| `~/.workbuddy/skills` | ~9M | 进包。重建要翻文档找来源 |
| `~/.workbuddy/mcp.json` | 4K | 进包。重配要重走 OAuth |
| `~/.workbuddy/SOUL.md` 等身份记忆文件 | 数十 K | 进包。丢了人格设定就没了 |
| `~/.npm/_npx` | ~614M | 不进。`npx` 一条命令拉回 |
| `~/Developer/hyperframes-src` | 226M | 不进。`git clone` 常被拦，但 codeload 稳定 |
| `~/.workbuddy/binaries` | 469M | 不进。随 App 安装 |
| `~/.workbuddy/plugins` | 231M | 不进。marketplace 自动补 |
| `cut-motion/jobs` | ~6.5M | 不进。是测试产物 |

若某机器已有大目录想省去下载，可在 backup 的 `EXCLUDES` 之外单独打包，但通常没必要。
