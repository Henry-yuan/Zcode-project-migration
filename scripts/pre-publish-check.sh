#!/usr/bin/env bash
# 发布前脱敏自查——每次提交前/开源前跑一次
# 用法：bash scripts/pre-publish-check.sh
#
# 背景：sha256 是无盐哈希，若文档里同时出现「真实路径」和「它的哈希」，
# 第三方一次计算即可反推。本脚本专门查这类组合泄露，以及 git 历史残留。

set -u
cd "$(dirname "$0")/.." || exit 1
FAIL=0

echo "=== 1. 身份与凭据类 ==="
# 分段拼接正则：避免本脚本自身的定义行被当成命中（git grep 会扫 scripts/）
# 关键字从本地未跟踪的 scripts/.patterns.local 读取——脚本本身不含任何真实名
if [ -f scripts/.patterns.local ]; then . scripts/.patterns.local; else
  echo "  ⚠️ 未找到 scripts/.patterns.local，跳过身份类扫描（请复制 .patterns.local.example）"; PAT1='__NOFILE__'; fi
# 排除：LICENSE（署名是开源惯例，应保留）、scripts/（本脚本，其正则定义会自我命中）
EXC=(":!LICENSE" ":!scripts/")
if git grep -nIE "$PAT1" -- "${EXC[@]}" 2>/dev/null; then
  echo "  ❌ 发现疑似真实身份/项目名"; FAIL=1
else
  echo "  ✓ 工作区无命中"
fi

echo
echo "=== 2. 真实项目名（按需扩充 PAT）==="
PAT2="${PAT2_LOCAL:-__NOFILE__}"
if git grep -nIE "$PAT2" -- "${EXC[@]}" 2>/dev/null; then
  echo "  ❌ 发现疑似真实项目名"; FAIL=1
else
  echo "  ✓ 工作区无命中"
fi

echo
echo "=== 3. git 历史残留（关键：已删除的内容仍可被挖出）==="
# 注意：git log 的 pathspec 排除语法是 -- ':!path'，且本脚本自身（scripts/）
# 含有这些关键字的正则定义行，必须排除，否则会自我误报
HIST=$(git log --all -p -- ':!scripts/' 2>/dev/null | grep -icE "${PAT_ALL_LOCAL:-__NOFILE__}")
HIST=${HIST:-0}
if [ "$HIST" -gt 0 ]; then
  echo "  ❌ 历史中仍有 $HIST 处真实项目名 → 需重建 git 历史"
  echo "     做法：备份文件 → mv .git ~/.Trash/ → git init → 重新提交"
  FAIL=1
else
  echo "  ✓ 历史无命中"
fi

echo
echo "=== 4. 哈希自洽性（示例哈希必须等于示例路径的 sha256 前16位）==="
python3 - <<'PY'
import hashlib, re, sys
src = open("docs/binding-mechanisms.md").read()
rows = re.findall(r'`~/Projects/([^`]+)`.*?`([a-z-]+)-([0-9a-f]{16})`', src)
bad = 0
for path, prefix, h in rows:
    calc = hashlib.sha256(('/Users/<user>/Projects/' + path).encode()).hexdigest()[:16]
    if calc != h:
        print(f"  ❌ {path}: 表={h} 实际={calc}")
        bad += 1
if bad: sys.exit(1)
print(f"  ✓ {len(rows)} 行哈希全部自洽")
PY
[ $? -ne 0 ] && FAIL=1

echo
echo "=== 5. 文档内表格 vs 代码函数自洽性 ==="
python3 - <<'PY'
import re, sys
src = open("docs/binding-mechanisms.md").read()
m = re.search(r'def sanitize\(name\):\n(?:    .*\n)+', src)
ns = {}; exec("import re\n" + m.group(0), ns)
rows = re.findall(r'\| `([^`]+)` \| `([^`]+)` \|', src[src.index("**对照表**"):src.index("**横线数量怎么数**")])
bad = sum(1 for n, e in rows if ns['sanitize'](n) != e)
for n, e in rows:
    if ns['sanitize'](n) != e: print(f"  ❌ {n}: 表={e} 实际={ns['sanitize'](n)}")
if bad: sys.exit(1)
print(f"  ✓ {len(rows)} 行与函数一致")
PY
[ $? -ne 0 ] && FAIL=1

echo
if [ "$FAIL" -eq 0 ]; then echo "✅ 全部通过"; else echo "❌ 存在问题，请先修复"; fi
exit $FAIL