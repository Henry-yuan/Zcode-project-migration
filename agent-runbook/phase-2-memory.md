# Phase 2：记忆迁移（文件层，低风险）

> 迁移"AI 工具的项目记忆"。这是最安全的阶段：**纯文件操作，可随时 `mv` 回去**。
> 会话（对话历史）属于 Phase 3。

---

## 步骤 2.1：停服（仅当有服务绑定时）

```bash
launchctl unload ~/Library/LaunchAgents/<label>.plist    # 注意是 unload 不是 kill
# 验证真的停了
launchctl list | grep <label>        # 应无输出
lsof -iTCP:<port> -sTCP:LISTEN        # 应无输出
```
> 如果目标工具（如 ZCode）自身在运行，**Phase 2 不用停它**（记忆目录改名可以在它运行时做）；但 **Phase 3 改数据库必须停**。

## 步骤 2.2：备份

```bash
TS=$(date +%Y%m%d-%H%M%S)
BK=~/Desktop/migration-backup-$TS
mkdir -p "$BK"

# ⚠️ 关键：ZCode 的库是 WAL 模式，直接 cp 主库会丢数据
#    （未 checkpoint 的数据在 -wal 文件里）。用 .backup 做在线安全快照，
#    无需停 ZCode 也能拿到一致副本。
sqlite3 ~/.zcode/cli/db/db.sqlite ".backup '$BK/db.sqlite'"
sqlite3 ~/.zcode/cli/db/tasks-index.sqlite ".backup '$BK/tasks-index.sqlite'"

# 备份要改的记忆目录
cp -R ~/.zcode/cli/memories/projects/<记忆目录名> "$BK/" 2>/dev/null

# 验证快照可用（不只看文件存在）
sqlite3 "$BK/db.sqlite" "SELECT COUNT(*) FROM session;"
echo "备份完成: $BK"
```

> **为什么不用 `cp`**：`db.sqlite-wal` 里可能有未落盘的写入，cp 三件套也不是原子快照——ZCode 正在写时可能拷到不一致状态。`.backup` 是 SQLite 官方的在线备份命令，保证副本自洽。
> 阶段 3 停服后会再备份一次，那次可以用 `cp`（此时无写入）。

## 步骤 2.3：搬文件

同盘用 `mv`（秒级，inode 不变）。跨盘才需要拷贝。
```bash
mv /旧路径/项目A /新路径/项目A
```
> 同盘 `mv` 后，**旧进程仍持有旧路径句柄**——见 pitfalls #4，跑服务可能要重启。

## 步骤 2.4：重命名项目（如果同时改名）

改名会让哈希和前缀都变，必须重算：

```bash
python3 - <<'PYEOF'
import hashlib, os, re
old_path = "/旧路径/项目A"
new_path = "/新路径/项目A-english-name"
memdir = os.path.expanduser("~/.zcode/cli/memories/projects")

old_h = hashlib.sha256(old_path.encode()).hexdigest()[:16]
new_h = hashlib.sha256(new_path.encode()).hexdigest()[:16]

# 名字部分（前缀）净化规则
def sanitize(name):
    s = re.sub(r'[^a-z0-9._-]+', '-', name.lower())
    return s.strip('-') or 'project'

old_name = sanitize(os.path.basename(old_path))
new_name = sanitize(os.path.basename(new_path))
print(f"旧记忆目录: {old_name}-{old_h}")
print(f"新记忆目录: {new_name}-{new_h}")
PYEOF
```
> ⚠️ **净化规则必须先验证**（见 `../docs/binding-mechanisms.md` 第 1.2 节），不要直接信推断。
> 纯中文名会让前缀退化成 `project`。

## 步骤 2.5：改名记忆目录

```bash
OLD=~/.zcode/cli/memories/projects/<旧名>-<旧哈希>
NEW=~/.zcode/cli/memories/projects/<新名>-<新哈希>

# ⚠️ 必须先检查：目标已存在时 mv 会「静默嵌套」（不报错、退出码 0，
#    结果是 NEW/OLD/），记忆依然读不到。这是 1.5 节「幽灵目录」场景的典型踩法。
if [ -e "$NEW" ]; then
  echo "❌ 目标已存在：$NEW"
  echo "   请先判断它是什么（空壳？部分记忆？），合并或移入废纸篓后再继续"
  exit 1
fi

mv -n "$OLD" "$NEW" && ls -d "$NEW" && echo "✅ 改名完成"
```

> `mv -n`（no-clobber）是第二道保险：目标存在时拒绝执行而非嵌套。
> 若已经发生嵌套（`ls "$NEW"` 看到里面有同名子目录），把子目录内容提到 `$NEW` 下再删掉空壳即可。

## 步骤 2.6：修正记忆内容里的旧路径

```bash
grep -rln "旧绝对路径" ~/.zcode/cli/memories/projects/<新记忆目录> | while read f; do
  sed -i '' 's|旧绝对路径|新绝对路径|g' "$f"
done
```

## 步骤 2.7：其它工具的绑定层（若有）

仅当用户明确表示同期使用其它 AI 工具时才需要。**本仓库不提供它们的做法**——请让用户按其官方文档处理，或参照 [`../docs/binding-mechanisms.md` 第四节](../docs/binding-mechanisms.md) 的通用侦察步骤判断绑定类型。

**通用纪律**（无论哪种绑定类型）：
- 删改任何按路径命名的目录前，**先看内容确认归属**——路径变形会导致不同项目生成相同标识；
- 涉及数据库的一律先备份，且改前必须停对应工具。

## 步骤 2.8：修 venv（如果有）

```bash
# 注意：venv 在子目录时不要用 dirname 推导基准（pitfalls #5），整串替换
sed -i '' 's|/旧/绝对/路径|/新/绝对/路径|g' <venv路径>/bin/*
<venv路径>/bin/pip --version     # 验证复活
```

## 步骤 2.9：重建符号链接

```bash
ln -sfn /新路径/项目A/.agents/skills/<skill> ~/.agents/skills/<skill>
# 验证
find ~/.agents/skills ~/.zcode/skills \
     -maxdepth 1 -type l ! -exec test -e {} \; -print    # 应无输出
```

## 步骤 2.10：修复路径引用

只改"会执行的"和"文档导航类"，**不改测试数据/快照**：

```bash
grep -rln --exclude-dir={.git,node_modules,venv,.venv,__pycache__,dist,build} \
     "旧绝对路径" /新路径/项目A
# 逐个判断后 sed 替换
```

## 步骤 2.11：起服务并验证

```bash
launchctl load ~/Library/LaunchAgents/<label>.plist
sleep 3
launchctl list | grep <label>        # 有 PID、退出码 0
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:<port>/
docker ps --format '{{.Names}} {{.Status}}'   # Up (healthy)
```

## 步骤 2.12：对比基线（零漂移验证）

用 Phase 1.1 记录的基线对比：
- git 未提交改动数是否一致
- 文件数是否一致

**Phase 2 结束 → 请用户在目标项目上打开 AI 工具，问"你的记忆文件里有什么"。**
能读出原来的记忆才算成功。若失败，见 `rollback.md`。