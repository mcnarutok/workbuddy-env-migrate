#!/usr/bin/env python3
"""Publish this repository to GitHub through the REST API instead of `git push`.

Why this exists: on some networks (corporate TLS interception, for example)
github.com:443 gets reset during the TLS handshake while api.github.com stays
reachable. `git push` dies with "Recv failure: Connection reset by peer" and
no amount of re-authentication fixes it. This script does the same
blobs -> tree -> commit -> ref dance over the API, which is reachable.

Requires the `gh` CLI, authenticated (`gh auth login`).

Usage:
    python3 scripts/publish-api.py                     # commit current contents
    python3 scripts/publish-api.py -m "Fix redaction"  # custom commit message
    python3 scripts/publish-api.py --dry-run           # show what would change
"""

import argparse
import base64
import json
import subprocess
import sys
from pathlib import Path

REPO = "mcnarutok/workbuddy-env-migrate"
BRANCH = "main"
ROOT = Path(__file__).resolve().parent.parent
MESSAGE = """Add WorkBuddy environment migration skill

Packages the text-based parts of a WorkBuddy install - user-level skills,
mcp.json, identity and memory files - into a tarball for transfer to another
machine, and rebuilds the large dependency tree afterwards.

Credentials are redacted by default: mcp.json never enters the archive
directly, a sanitized copy does, so the package is safe to publish.
--with-secrets is available for local cold backups only.

Also ships a ChatCut token refresher (check / refresh / full) because the
MCP access_token expires after an hour and every machine move invalidates it.

Scripts only read their manifest paths, make no outbound calls beyond the
ChatCut auth endpoints, and write nothing outside $HOME."""
EXECUTABLES = {"workbuddy-migrate.sh", "chatcut-refresh.sh"}


def gh(method: str, path: str, payload: dict | None = None) -> dict:
    # gh api 的 -f 把值当扁平字符串并二次 JSON 编码，
    # 嵌套结构必须用 --input 传整个请求体
    with open("/tmp/publish-api-payload.json", "w") as fh:
        json.dump(payload or {}, fh)
    out = subprocess.run(
        ["gh", "api", "-X", method, path, "--input", "/tmp/publish-api-payload.json"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        sys.exit(f"[{method} {path}] 失败:\n{out.stderr[:600]}")
    return json.loads(out.stdout)


def ref_sha() -> str | None:
    try:
        return gh("GET", f"repos/{REPO}/git/ref/heads/{BRANCH}")["object"]["sha"]
    except SystemExit:
        return None          # 空仓库没有 ref，git-data 端点一律 409


def take_files():
    files = [p for p in sorted(ROOT.rglob("*"))
             if p.is_file() and ".git" not in p.relative_to(ROOT).parts]
    return [(p.relative_to(ROOT).as_posix(), p) for p in files]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("-m", "--message", default=MESSAGE,
                    help="commit message (defaults to the initial-commit text)")
    args = ap.parse_args()

    entries = take_files()
    parent = ref_sha()
    print(f"分支 {BRANCH} 当前: {parent[:8] if parent else '(空仓库)'}")
    print(f"待提交 {len(entries)} 个文件\n")

    if args.dry_run:
        for rel, _ in entries:
            print(f"  would upload  {rel}")
        return

    blobs = []
    for rel, path in entries:
        if parent is None:
            # 空仓库：Contents API 是唯一能建分支的方式（git-data 端点返回 409）
            gh("PUT", f"repos/{REPO}/contents/{rel}",
               {"message": "chore: initialize repository",
                "content": base64.b64encode(path.read_bytes()).decode(),
                "branch": BRANCH})
            print(f"  分支初始化     {rel}")
            parent = ref_sha()
        b64 = base64.b64encode(path.read_bytes()).decode()
        sha = gh("POST", f"repos/{REPO}/git/blobs",
                 {"content": b64, "encoding": "base64"})["sha"]
        blobs.append({"path": rel,
                      "mode": "100755" if path.name in EXECUTABLES else "100644",
                      "type": "blob", "sha": sha})
        print(f"  blob          {rel}  {sha[:8]}")

    tree = gh("POST", f"repos/{REPO}/git/trees", {"tree": blobs})
    print(f"\ntree    {tree['sha'][:8]}   {len(blobs)} entries")

    # parents 必须显式给出：省略时 GitHub 未必用当前分支 head，
    # 之后 PATCH ref 会被判成 not a fast forward
    commit = gh("POST", f"repos/{REPO}/git/commits",
                {"message": args.message, "tree": tree["sha"], "parents": [parent]})
    print(f"commit  {commit['sha'][:8]}")

    gh("PATCH", f"repos/{REPO}/git/refs/heads/{BRANCH}", {"sha": commit["sha"]})
    print(f"\n分支已更新 -> {commit['sha'][:8]}")
    print(f"https://github.com/{REPO}/tree/{BRANCH}")


if __name__ == "__main__":
    main()
