# ZCode 绑定机制详解

> **本文专注 ZCode**——说明它如何把"项目身份"与文件路径绑定，以及路径变化时会发生什么。
> 所有结论均来自实际存储结构的实证（非猜测），实测环境：macOS (Apple Silicon)，2026-09。
> 其他 AI 工具只在第 2 节以**简表**形式出现（结论 + 去哪查），不展开。

---

## ⚠️ 先划清边界：本文档不涉及"跨工具迁移"

一个常见误解，这里说清楚：

| 场景 | 本文档是否覆盖 |
|---|---|
| 项目换目录/改名后，**ZCode** 的记忆与会话失联 | ✅ **本文档的全部范围** |
| 把会话从别的工具搬进 ZCode | ❌ 不涉及，也不建议尝试 |

各 AI 工具的会话都是独立的私有格式，消息结构、工具调用记录字段互不相同，强行转换会丢失大量上下文且极易出错。若你的诉求是换工具，可迁移的是**记忆**（把项目约定整理成 `AGENTS.md` / `MEMORY.md`），而非会话记录。

---

## 零、通用心法

绑定层总是下面这几类之一（ZCode 属于第一类与第三类，下文逐项展开）：

| 类型 | 表现 | 迁移手段 | 风险 |
|---|---|---|---|
| **文件名型** | 项目身份编码在目录名里（如 `feed-reader-<hash>`） | `mv` 改名 | 极低 |
| **数据库型** | 存一张表，一行记录里有路径字段 | SQL `UPDATE` | 中（需停服务+备份） |
| **无绑定** | 只在会话内部记路径，不参与分组 | 什么都不用做 | 无 |

**侦察方法**：不要靠猜。直接翻存储目录——
```bash
ls ~/.zcode/cli/memories/projects/   # ZCode 的记忆目录
ls ~/.zcode/cli/db/                  # ZCode 的数据库
ls ~/.zcode/cli/rollout/             # ZCode 的会话日志（不用动，仅了解位置）
```

---

## 一、ZCode

### 1.1 记忆绑定：文件名型

```
~/.zcode/cli/memories/projects/<名字>-<sha256(项目绝对路径)前16位>/memory/*.md
```

**规则验证**（下表哈希为**示例路径**算出的值，可自行验证；真实项目路径不公开，避免「路径+无盐哈希」被反推。5 行均符合 1.2 的净化规则）：

| 项目路径 | 记忆目录名 |
|---|---|
| `~/Projects/opensource/feed-reader` | `feed-reader-58d58bcac6408691` |
| `~/Projects/search-engine` | `search-engine-22fa16799054239d` |
| `~/Projects/个人网站` | `project-e98263e0b2a4df07` | 纯中文 → 退化
| `~/Projects/知识库` | `project-ab1397b0ce7e19b4` | 纯中文 → 退化 |
| `~/Documents/legacy/微调` | `project-c32ff51f86aca11b` ← 孤儿目录的由来 |

**哈希计算**（验证与迁移都需要）：
```python
import hashlib
hashlib.sha256("/Users/you/Projects/your-project".encode()).hexdigest()[:16]
```

### 1.2 前缀（名字部分）的净化规则

前缀由**项目文件夹名**决定，规则：

```
非 [a-z0-9._-] 的字符 → 整段替换为一个 "-"
然后掐掉开头和结尾的 "-"
若结果为空 → 回退为 "project"
```

对应的函数（**执行前请用你的真实样本校准**，见本节末尾）：

```python
import re
def sanitize(name):
    """推定的净化规则——不是官方文档，工具升级后可能变化"""
    return re.sub(r'[^a-z0-9._-]+', '-', name.lower()).strip('-') or 'project'
```

**对照表**（本表所有结果均由上述函数实跑验证，2026-09）：

| 文件夹名 | 净化结果 | 说明 |
|---|---|---|
| `content-sync` | `content-sync` | 纯 ASCII，最干净 |
| `中文段-video-fetch` | `video-fetch` | 中文段在前 → 变一个 `-` → 在开头 → 被掐掉 |
| `纯中文样例` | `project` | ⚠️ **纯中文 → 前缀退化，名字白起** |
| `portal-app` | `portal-app` | 纯 ASCII 最稳 |
| `中文段-podcast` | `podcast` | 中文在前被掐掉，干净 |
| `项目A-2024` | `a-2024` | 中文变 `-` 被掐，ASCII 字母保留并小写化 |
| `my_project.v2` | `my_project.v2` | 下划线、点、版本号都保留 |
| `abc-内容采集-def` | `abc---def` | ⚠️ 中文在**中间**：中文段变 1 个 `-`，两侧手写 `-` 各留 1 个 → **三个**横线 |

**横线数量怎么数**（最容易搞错的一处）：
```
abc-内容采集-def
   ↑        ↑
   |        └─ 中文整段"内容采集"变 1 个 "-"
   └─ 手写的 "-"（×2 个）

结果 = abc + "-" + "-" + "-" + def = abc---def    ← 三个，不是两个
```

**实践规则**：
- ✅ **中文在前、英文在后**（`中文段-video-fetch`）→ 结果最干净，前缀 = 纯英文段
- ❌ **纯中文**（`纯中文样例`）→ 前缀退化，不可读
- ⚠️ **中文夹在英文中间**（`abc-内容采集-def`）→ 会产生多余横线，能用但难看

### ⚠️ 这条规则的可信度（动手前务必校准）

上面的 `sanitize()` 是**根据少量样本推定**的，**不是官方文档**，工具升级后可能变化。

**校准方法**（用你自己机器上的真实样本验证，多验几个）：
```bash
# ① 找现成样本：你机器上迁移过的项目就是天然对照组
ls ~/.zcode/cli/memories/projects/
#   看到形如 <名字>-<16位哈希> 的目录，而对应项目目录名是「中文段-英文段」
#   → 说明 sanitize("中文段-英文段") 应该等于 "<英文段>"

# ② 把样本代进函数，逐个核对（把 <你的项目名> 换成真实目录名）
python3 -c "
import re
def s(n): return re.sub(r'[^a-z0-9._-]+','-',n.lower()).strip('-') or 'project'
for n in ['中文段-英文段','纯中文样例','<你的项目名>']:
    print(repr(n), '→', repr(s(n)))"
```
**任何一个样本对不上，就以实测为准**——工具的真实规则永远优先于本文档。

### 1.3 会话绑定：数据库型

```
~/.zcode/cli/db/db.sqlite        （约 650MB，WAL 模式）
```

`session` 表关键字段：

| 字段 | 内容 |
|---|---|
| `directory` | 会话启动时的工作区绝对路径 ← **唯一可信的真值字段，也是你该用的匹配条件** |
| `project_id` | 由路径派生的分组键（UI 上按它归类会话）⚠️ **有损、会撞名，见下方警告** |
| `workspace_id` | 通常为空 |
| `path` | 通常为空，若非空且含旧路径一并改 |

### ⚠️⚠️ 高危：`project_id` 会撞名，绝不能用它做 UPDATE 的匹配条件

`project_id` 不是记忆目录那个哈希，而是另一套**有损 slug**——它会丢弃路径后半段。**两个完全无关的目录可能共享同一个 `project_id`**。

**本机实测证据**：
```sql
SELECT project_id, COUNT(DISTINCT directory), GROUP_CONCAT(DISTINCT directory)
FROM session GROUP BY project_id HAVING COUNT(DISTINCT directory) > 1;
```
```
proj_users-<user>-documents | 2 | /Users/<user>/Documents/dir-a,
                                        /Users/<user>/Documents/dir-b
```
→ 两个毫不相干的项目，共享同一个 `project_id`。

**后果**：如果你写 `UPDATE session SET ... WHERE project_id = 'xxx'`，**会把两个项目的会话静默合并**。这比中文 slug 撞名更隐蔽（至少 slug 长得一样，这个是字段本身被截断了）。

**铁律**：
```sql
-- ✅ 正确：永远用 directory 精确匹配
UPDATE session SET directory='新路径', project_id='<锚定值>'
 WHERE directory='旧路径';

-- ❌ 错误：project_id 不唯一，会误伤别的项目
UPDATE session SET directory='新路径' WHERE project_id='proj_xxx';
```

`project_id` 的作用仅是**分组显示**，所以把它设成目标工作区的锚定值即可，**不要拿它当查询条件**。

**其它 ZCode 数据库**：`~/.zcode/cli/db/tasks-index.sqlite`（任务/自动化，按路径关联的表包括 `tasks`、`task_group_members`、`task_group_workspace_bootstraps`、`automations`、`automation_runs` 等）。⚠️ **改它之前必须备份**——runbook 阶段 3 会给备份命令。

### 1.4 会话本体（不用碰）

```
~/.zcode/cli/rollout/model-io-<session-id>.jsonl
~/.zcode/cli/db/db.sqlite 的 session / session_entry / message 表
```
按 session ID 存储，**与路径完全无关**。这是"最坏情况可回滚"的基础。

### 1.5 记忆键的陷阱：幽灵目录

在**已删除的路径**下开新会话，ZCode 会按那个路径算哈希并创建一个**空记忆目录**。如果你之前把记忆目录改过名，这里会留下孤儿空壳。
→ **测试迁移效果时，一定要在新路径的工作区里打开**，不要在旧路径（哪怕它已经不存在）开会话。

---

## 二、迁移期间若同期使用其它 AI 工具

**别假设"都一样"**——其它 AI 工具各有自己的绑定层，存储结构与 ZCode 完全不同。

通用检查动作见[第四节](#四通用侦察步骤)：列它的数据目录 → grep 旧路径 → 判断绑定类型。判断准则：目录名含 16 位 hex → 文件名哈希型；路径变形（中文变横线）→ slug 型；有 `.sqlite` 且表里有路径字段 → 数据库型；**grep 全无命中 → 无绑定，无需任何操作**。

> 本文档只覆盖 ZCode，不提供其它工具的具体做法。

---

## 三、ZCode 机制速查

| 项 | 位置 / 规则 | 搬家必处理 |
|---|---|---|
| **记忆目录** | `~/.zcode/cli/memories/projects/<名字>-<sha256(路径)[:16]>/` | ✅ `mv` 改哈希部分 |
| **记忆前缀** | 文件夹名净化（中文被替换、纯中文退化 `project`） | ✅ 改名项目时一并算 |
| **会话归属** | `~/.zcode/cli/db/db.sqlite` → `session.directory` | ✅ SQL `UPDATE`（需停 ZCode + 备份） |
| **会话分组键** | `session.project_id` | ✅ 设为目标工作区锚定值（**不可用于 WHERE**） |
| **任务/自动化** | `~/.zcode/cli/db/tasks-index.sqlite` 相关 7 张表 | ⚠️ 同样按路径关联，需一并改 |
| **会话本体** | `~/.zcode/cli/rollout/*.jsonl` | ❌ **不要动** |
| **会话内容表** | `session_entry` / `message` 等 | ❌ **不要动** |
| 现成迁移工具 | **无**（全网检索确认） | — |

**一句话记住**：改 3 处（记忆目录名、`directory`、`project_id`），不动 2 处（rollout 日志、内容表）。

---

## 四、给陌生工具的通用侦察步骤

遇到不认识的工具，按这五步自己摸出来：

1. **列存储目录**：`ls -la ~/<工具数据目录>`，找 `projects/ memories/ sessions/ *.sqlite *.json`
2. **grep 老路径**：`grep -rl "旧项目绝对路径" ~/<工具数据目录> 2>/dev/null` —— 命中的文件就是绑定层
3. **看目录名形态**：含 16 位 hex → 文件名哈希型；中文变横线的长串 → 路径 slug 型
4. **看到 `.sqlite`**：`sqlite3 <db> ".tables"`，`.schema <表名>`，找含 `path/directory/project` 字样的字段
5. **⚠️ 检查字段唯一性**（最容易漏的一步）：
   ```bash
   sqlite3 <db> "SELECT <疑似ID字段>, COUNT(DISTINCT <路径字段>)
              FROM <表> GROUP BY <疑似ID字段> HAVING COUNT(DISTINCT <路径字段>) > 1;"
   ```
   有输出 = **这个 ID 字段会撞名，绝不能拿它当 WHERE 条件**。

---
