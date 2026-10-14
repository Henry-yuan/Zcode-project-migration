# Phase 3：会话迁移（数据库层，中风险）

> 迁移"历史会话在 UI 里的归属"。**会话内容本身永远不用动**，只改"索引"。
>
> ⚠️ **前置条件**：ZCode（或对应工具）必须**完全退出**。运行中改库会锁、甚至损坏。
>
> ⚠️ **平台**：本阶段命令（`launchctl`、`lsof`、`~/Desktop`）为 **macOS 语法**。其他平台请换成各自的服务管理命令；`sqlite3` 与 `cp` 是通用的。**方法通用，命令需适配。**

---

## 步骤 3.1：清点所有待迁移会话

```bash
sqlite3 ~/.zcode/cli/db/db.sqlite \
  "SELECT directory, COUNT(*) AS n FROM session
   WHERE directory LIKE '/Users/you/Documents/%'
   GROUP BY directory ORDER BY n DESC;"
```

**把这份完整清单列给用户看**，并逐一确认每个旧路径该映射到哪个新路径。
> ⚠️ **注意子目录行**：有时会话是在项目的**子目录**里开的（如 `项目/待发布/xxx`），它们是独立的 directory，要单独映射，不能只映射项目根目录。

## 步骤 3.2：构建映射表

```bash
# 格式：旧路径|新路径|会话数
cat > /tmp/migrate-map.txt <<'EOF'
/Users/you/Documents/old-project|/Users/you/Projects/new-project|42
/Users/you/Documents/old-client|/Users/you/Projects/archive/old-client|19
EOF
```
明确排除：
- 留守不迁的目录
- **孤儿行**（指向已删目录的，如 git worktree 删掉后的残留）——无新路径可映射，保留原样

## 步骤 3.3：锚定目标 project_id（关键）

ZCode 用 `project_id` 给会话分组。**不要用规则推算**（只有 2 个样本佐证，容易错）。

**锚定法**：让用户在新工作区里打开工具、新开一个会话，然后从库里读出真实值：

```bash
# 先让用户操作：在 /新路径/项目A 下打开 ZCode 新开一个会话，然后退出 ZCode
# 再读：
sqlite3 ~/.zcode/cli/db/db.sqlite \
  "SELECT project_id, directory FROM session
   WHERE directory='/新路径/项目A' ORDER BY time_created DESC LIMIT 1;"
```

**如果无法新建会话**（用户只是整理文件、暂不打算用 ZCode）：可以**保留原 `project_id` 不变**——它只影响 UI 里的分组显示，**不影响会话内容与可见性**。等将来真在目标路径下开了会话，再回来补这一步。

**省力技巧**（先查现成的，别麻烦用户）：
```bash
sqlite3 ~/.zcode/cli/db/db.sqlite \
  "SELECT DISTINCT directory, project_id FROM session
   WHERE directory LIKE '/Users/you/Projects/%';"
```
> 💡 中文项目名的 `project_id` 会丢弃中文字段 → 多个中文项目可能**共用同一个值**。若上面查询显示 ≥2 个中文项目的 `project_id` 相同，就复用；不同则逐个锚定。

## 步骤 3.4：让用户退出工具（必须）

```bash
pgrep -fl "ZCode" | grep -v grep     # 应无输出
lsof ~/.zcode/cli/db/db.sqlite 2>/dev/null   # 应无输出
```

## 步骤 3.5：备份数据库（三件套）

```bash
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p ~/Desktop/db-backup-$TS
# 已停服，此时 cp 是安全的（无写入者）
cp ~/.zcode/cli/db/db.sqlite           ~/Desktop/db-backup-$TS/
cp ~/.zcode/cli/db/db.sqlite-wal       ~/Desktop/db-backup-$TS/ 2>/dev/null
cp ~/.zcode/cli/db/db.sqlite-shm       ~/Desktop/db-backup-$TS/ 2>/dev/null
# ⚠️ tasks-index 也必须备份——3.8 会改它，没有备份就无法回滚
cp ~/.zcode/cli/db/tasks-index.sqlite      ~/Desktop/db-backup-$TS/ 2>/dev/null
cp ~/.zcode/cli/db/tasks-index.sqlite-wal  ~/Desktop/db-backup-$TS/ 2>/dev/null
cp ~/.zcode/cli/db/tasks-index.sqlite-shm  ~/Desktop/db-backup-$TS/ 2>/dev/null
# 验证两个快照都能打开
sqlite3 ~/Desktop/db-backup-$TS/db.sqlite "PRAGMA quick_check;"
sqlite3 ~/Desktop/db-backup-$TS/tasks-index.sqlite "PRAGMA quick_check;" 2>/dev/null
echo "备份: ~/Desktop/db-backup-$TS"
```

## 步骤 3.6：试点一个项目（建议选会话数最少的）

```bash
# 改前基线
sqlite3 ~/.zcode/cli/db/db.sqlite \
  "SELECT COUNT(*) FROM session WHERE directory='/旧路径/项目A';"

# 执行（事务包裹）
sqlite3 ~/.zcode/cli/db/db.sqlite <<'EOF'
BEGIN;
SELECT id, title FROM session WHERE directory='/旧路径/项目A';   -- 预览
UPDATE session
   SET directory = '/新路径/项目A',
       project_id = '<锚定值>'
 WHERE directory = '/旧路径/项目A';
SELECT changes() AS updated;
COMMIT;
EOF
```
`changes()` 必须等于基线数。不等则 `ROLLBACK` 并排查。

## 步骤 3.7：请用户验证试点结果

用户重新打开工具，在新工作区下确认：
- 历史会话列表出现（✅ 才是成功）
- 点开会话内容完整、可继续对话
- 旧路径下不再显示这些会话

**用户确认后**才进批量。

## 步骤 3.8：批量执行

按映射表逐条 UPDATE（**一条一条写，不要写循环**）：

```bash
sqlite3 ~/.zcode/cli/db/db.sqlite <<'EOF'
BEGIN;
UPDATE session SET directory='/新路径1', project_id='<锚定值1>' WHERE directory='/旧路径1';
UPDATE session SET directory='/新路径2', project_id='<锚定值2>' WHERE directory='/旧路径2';
-- ……（每对一条）
COMMIT;
EOF
```

**如果有 tasks-index.sqlite 也按路径关联**（tasks / task_group_members / task_group_workspace_bootstraps / automations / automation_runs 等表），用同样方法处理。

## 步骤 3.9：完整性核对（三项全过）

```bash
# a) 数据库健康
sqlite3 ~/.zcode/cli/db/db.sqlite "PRAGMA quick_check;"    # 应 ok
# b) 总会话数不变（与改前对比）
sqlite3 ~/.zcode/cli/db/db.sqlite "SELECT COUNT(*) FROM session;"
# c) 会话内容文件数不变（证明没碰内容）
ls ~/.zcode/cli/rollout/ | wc -l
```

## 步骤 3.10：验收

请用户抽查 2-3 个会话数最多的项目，确认会话完整可见、可 resume。

---

## ⚠️⚠️ 高危警告：`project_id` 会撞名，绝不能当 WHERE 条件

ZCode 的 `project_id` 是**有损 slug**，两个完全无关的目录可能共享同一个值。本机实测：

```sql
SELECT project_id, COUNT(DISTINCT directory), GROUP_CONCAT(DISTINCT directory)
FROM session GROUP BY project_id HAVING COUNT(DISTINCT directory) > 1;
-- proj_users-<user>-documents | 2 | .../dir-a , .../dir-b
```

```sql
-- ✅ 唯一正确写法：永远用 directory 精确匹配
UPDATE session SET directory='新路径', project_id='<锚定值>' WHERE directory='旧路径';

-- ❌ 会把多个项目的会话静默合并
UPDATE session SET directory='新路径' WHERE project_id='proj_xxx';
```

**开工前先跑上面那条检测 SQL**，把结果贴给用户确认。

---

## ⚠️ 不要做的事

- ❌ 不要 UPDATE / DELETE `session_entry`、`message` 等表——那是会话**内容**
- ❌ 不要碰 `rollout/` 目录
- ❌ 不要在工具运行时改库
- ❌ 不要用宽泛断言验收（如"Documents 下无会话"——那里还有守护不迁的项目）

---

**Phase 3 结束。** 任何一步不满意 → `rollback.md`。