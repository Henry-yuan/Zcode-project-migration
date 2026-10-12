# Phase 1：侦察与规划（只读）

> 本阶段**不做任何修改**。产出是一份交给用户确认的影响评估。

---

## 步骤 1.1：清点项目与基线

对每个待迁项目，记录**迁移前基线**（后面要对比"零漂移"）：

```bash
PROJ="/旧路径/项目A"
echo "== $PROJ"
git -C "$PROJ" status --porcelain | wc -l          # 未提交改动数
git -C "$PROJ" branch --show-current              # 当前分支
find "$PROJ" -type f | wc -l                       # 文件总数
du -sh "$PROJ"                                     # 体积
ls -d "$PROJ"/.git 2>/dev/null && git -C "$PROJ" worktree list   # 是否有 worktree
```

**记录这些数字，写进你的工作笔记。** 验收阶段要对比。

## 步骤 1.2：识别每类绑定

按 `../docs/binding-mechanisms.md` 的四类去查，**不要靠猜**：

### A. venv / 环境（会执行，需要修）
```bash
find "$PROJ" -maxdepth 4 \( -name "venv" -o -name ".venv" \) -type d 2>/dev/null
# 记录 venv 位置；注意是否在子目录里（会导致替换陷阱）
cat "$PROJ"/<venv路径>/pyvenv.cfg 2>/dev/null | head -5
```

### B. 后台服务（必须停）
```bash
# 1. LaunchAgent 指向它？
grep -l "$PROJ" ~/Library/LaunchAgents/*.plist 2>/dev/null
# 2. 有运行中的进程？
ps aux | grep -F "$PROJ" | grep -v grep
# 3. Docker 容器挂载它？
docker ps --format '{{.Names}}' 2>/dev/null | while read c; do
  docker inspect "$c" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' 2>/dev/null
done | grep -F "$PROJ"
```
**读 plist 全文**，把需要改的行号/内容记录下来（通常只有 1-2 处）。

### C. 符号链接
```bash
# 项目内
find "$PROJ" -type l 2>/dev/null | while read l; do
  [ -e "$l" ] && echo "OK  $l -> $(readlink "$l")" || echo "断链 $l -> $(readlink "$l")"
done
# 用户级（最容易漏！）
find ~/.agents/skills ~/.zcode/skills \
     -maxdepth 1 -type l ! -exec test -e {} \; -print 2>/dev/null
```

### D. AI 工具绑定
见步骤 1.3。

## 步骤 1.3：AI 工具绑定侦察

### ZCode
```bash
# 记忆目录：算旧路径哈希，反查是哪个记忆目录
python3 - <<'EOF'
import hashlib, os
old = "/旧路径/项目A"
h = hashlib.sha256(old.encode()).hexdigest()[:16]
mem = os.path.expanduser("~/.zcode/cli/memories/projects")
for d in os.listdir(mem):
    if d.endswith(h):
        print(f"✓ 记忆目录: {d}  ({len(os.listdir(os.path.join(mem,d)))} 项)")
        break
else:
    print("— 无记忆目录")
EOF

# 会话绑定
sqlite3 ~/.zcode/cli/db/db.sqlite \
  "SELECT directory, COUNT(*) FROM session WHERE directory LIKE '$old%' GROUP BY directory;"
```

### D-2. 同期使用的其它 AI 工具（若有）

**仅当用户明确表示同时使用多个 AI 工具时才做这一步。** 各工具机制不同，不能套用 ZCode 的结论——
先查有没有绑定层，再决定要不要修。**本仓库不提供其它工具的具体做法。**

**通用侦察动作**（不针对具体工具，路径由用户指定）：
```bash
# 1. 让用户列出该工具的数据目录，grep 旧路径——命中的文件就是绑定层
grep -rl "旧路径/项目A" <该工具的数据目录> 2>/dev/null

# 2. 也检查它自己的全局配置文件（记录项目路径、权限等）
grep -rl "旧路径/项目A" <该工具的全局配置> 2>/dev/null
```

**判断准则**：
- 目录名含 16 位 hex 哈希 → 文件名哈希型 → 算出新哈希后 `mv`
- 目录名是路径变形 → slug 型 → 算出新 slug 后 `mv`（⚠️ 改前先看内容，可能撞名）
- 有 `.sqlite` 且表里有路径字段 → 数据库型 → **需停工具 + 备份**
- **grep 全无命中 → 无绑定，无需任何操作**

若需要该工具的结论，请让用户提供其官方文档，不要凭印象推断。

## 步骤 1.4：路径引用双向扫描

**关键：双向**。已搬的引用留守的、留守的引用已搬的，都要查。

```bash
# ① 待迁项目内部的自引用
grep -rln --exclude-dir={.git,node_modules,venv,.venv,__pycache__,dist,build,site-packages} \
     "旧路径/项目A" "$PROJ" 2>/dev/null

# ② 其它所有地方的反向引用（含用户级配置）
grep -rln --exclude-dir={.git,node_modules,venv,.venv,__pycache__} \
     "旧路径/项目A" ~/Projects ~/Documents ~/.zcode ~/.config 2>/dev/null
```

**对每个命中文件分类**（这决定改不改）：
- 会执行的代码（`.py` `.sh` `.js` 且在调用路径）→ **要改**
- 文档 `.md`、README → **建议改**（AI 会照着迷路）
- **测试数据 / 快照 / 注释** → **不要改**（pitfalls #7）
- 历史存档（archive/ 里的）→ **不要改**（冻结语义）

## 步骤 1.5：产出影响评估报告

按**三档**给用户（不要一次改完）：

| 档 | 判定标准 | 例子 |
|---|---|---|
| 🔴 高（需先处理） | 有运行中服务/容器绑定 | 常驻 launchd 服务、Docker bind mount |
| 🟡 中（搬后要修） | venv、软链、会执行代码路径 | |
| 🟢 低（直接搬） | 无上述任何一项 | 纯文档项目、未被 AI 工具用过的项目 |

报告里必须包含：
1. 每个项目的档位 + 理由
2. 服务窗口的执行步骤与预计中断时长
3. 需要用户确认的待决事项
4. 明确说明**哪些不改及原因**

---

**Phase 1 结束。** 把报告给用户，得到"继续"指令后再进 Phase 2。