# 实战踩坑记录

> 下面每一条都是真实迁移过程中**实际踩到并付出时间**的坑。
> 如果你只读一份文档，读这份。

---

## 1. ⚠️ `kill` 进程 ≠ 停服务（KeepAlive 陷阱）

**现象**：以为 `kill <pid>` 停掉了后台服务，其实没停。

**原因**：LaunchAgent 配置里 `KeepAlive=true`（或 `KeepAlive` 字典），launchd 会在进程退出后**立刻重新拉起**。你以为在迁移、其实服务正在写你要移动的目录。

**正确做法**：
```bash
launchctl unload ~/Library/LaunchAgents/<label>.plist   # 停
# ... 迁移 ...
launchctl load   ~/Library/LaunchAgents/<label>.plist   # 起
```
**验证停干净了**（两条都过才算停）：
```bash
launchctl list | grep <label>    # 应无输出
lsof <数据库或数据文件路径>       # 应无进程持有
```
> 停机窗口尽量短：停 → 搬 → 修路径 → 起。实测 5 个 Docker 容器 down→up 约 1 分钟完成。

---

## 2. ⚠️ 用户级软链是最大盲区

**现象**：项目内所有引用都查过、都改对了，但某个 AI 工具"还是认不出 skill"。

**原因**：项目在 `~/.agents/skills/`、`~/.zcode/skills/` 这类用户级 skill 目录里有指向项目内的**软链**，它们写死绝对路径，搬家即断。而这类链接**不在项目目录里**，用 `grep -r` 扫项目是永远扫不到的。

**排查命令**（每次迁移必跑）：
```bash
find ~/.agents/skills ~/.zcode/skills \
     -maxdepth 1 -type l ! -exec test -e {} \; -print
```
**修复**：`ln -sfn <新路径> <链接>`（`-n` 很重要，防止链接指向链接）。

---

## 3. ⚠️ ZCode 的 `project_id` 会撞名（比 slug 撞名更隐蔽）

**现象**：两个完全无关的项目，`session.project_id` 是同一个值。

**原因**：`project_id` 是**有损 slug**——路径后半段会被丢弃。本机实测：
```sql
SELECT project_id, COUNT(DISTINCT directory), GROUP_CONCAT(DISTINCT directory)
FROM session GROUP BY project_id HAVING COUNT(DISTINCT directory) > 1;
-- proj_users-<user>-documents | 2 | .../dir-a , .../dir-b
```

**后果**：如果你用 `WHERE project_id='xxx'` 做 UPDATE，**会把两个项目的会话静默合并**——不报错，但数据乱了。

**纪律**：**永远用 `directory` 精确匹配**，`project_id` 只作为要写入的值，绝不作为查询条件。
```bash
# ✓ 正确
sqlite3 ~/.zcode/cli/db/db.sqlite \
  "UPDATE session SET directory='新路径', project_id='<锚定值>' WHERE directory='旧路径';"
# ❌ 错误：project_id 不唯一，会误伤别的项目
```

> 若同期使用其它 AI 工具，它们可能有各自的绑定层与撞名问题——同样遵循"改前先看内容"的纪律。

---

## 4. ⚠️ 同盘 `mv` 后旧进程还活着，但已"脚踏虚空"

**现象**：一个静态站点预览服务（astro preview）在项目改名/搬移后仍然在监听端口，但**所有请求返回 404**。

**原因**：同盘 `mv` 只是改目录登记，**不改变文件 inode**。旧进程仍持有旧路径的目录句柄，能响应但解析不到内容。

**修复**：重启进程即可（内容完好，只是句柄失联）。这是最省事的一类"坏了"——**先确认是句柄问题还是内容问题**：
```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:<port>/     # 服务活着
ls <新路径>/dist/index.html && echo "内容在"                       # 内容完好
# → 结论：重启进程
```

---

## 5. ⚠️ venv 在子目录时的替换陷阱

**现象**：修正 venv 里的脚本路径后，出现 `backend/backend/.venv/bin/python3.12`。

**原因**：venv 位于 `xxx/backend/.venv`，替换基准用了 `dirname(venv)`，得到 `xxx/backend`，拼接时又带了一次 `backend`。

**纪律**：**整串路径替换，不要用 `dirname` 推导**
```bash
# ✅ 对：显式写全
sed -i '' 's|/old/path/to/project|/new/path/to/project|g' xxx/backend/.venv/bin/*
# ❌ 错：dirname 推导，在子目录里会重复拼接
```
> 附带知识：venv 里的 `bin/pip` 等脚本靠 **shebang 里的绝对路径**找解释器。同一台机器上路径变了就失效，**改 shebang 即可复活，不需要重装依赖**（比重建快一个数量级）。验证：`venv/bin/pip --version`。

---

## 6. ⚠️ 幽灵记忆键

**现象**：测试迁移效果时在旧位置开会话 → AI 说"记忆库是空的" → 事后发现记忆目录里多了一个**空的**新目录。

**原因**：在**已删除/不存在的路径**下开会话，工具按那个路径算哈希，创建一个空记忆目录（占了你改名后的键位）。

**纪律**：验证迁移**必须在新路径的工作区**里打开。

---

## 7. ⚠️ 测试数据和注释里的路径不能改

**现象**：批量替换旧路径后，原本全绿的测试挂了 7 个。

**原因**：那 7 个测试里出现的 `~/Documents/test` 是**白名单功能测试的用例数据**（测的就是"这个路径在不在白名单里"），不是损坏的引用。

**纪律**：改路径前先分类——
- 会**执行**的代码引用 → 改
- 测试的**输入/期望值**、快照文件、注释里的举例 → **不改**

**验证方式**：改完跑全量测试。绿了才算改对（这也是最有说服力的验收标准）。

---

## 8. ⚠️ 改名前先 commit

**现象**：某个 worktree 被删除后，想找回里面的工作。

**现实**：git worktree 被删后，`git worktree list` 里没了；分支若也被删，`git log <branch>` 报 `unknown revision`。工作目录里**未提交**的内容**无法通过 git 找回**。

**纪律**：批量改名/搬家前，对未提交改动多的仓库先 `git commit` 留快照。多花的 1 分钟，换一个后悔药。

> 补充：已提交的分支被删后，可以用 `git fsck --unreachable` 找到悬空提交并 `git branch <name> <hash>` 复活——但**未提交内容没有这条路**。

---

## 9. ⚠️ 纯中文项目名会让记忆前缀退化

**现象**：想给自己的项目起个纯中文名让记忆目录可读，结果记忆目录还是 `project-<hash>`。

**原因**：前缀净化时中文被换成 `-`，全空 → 回退 `project`。

**规避**：中文名 + `-英文名` 组合（`中文段-video-fetch` → 前缀 `video-fetch`），中文在前最干净。

---

## 10. ⚠️ "确认可删"不等于"用 rm 删"

**现象**：用户确认了某个残留目录可以删，执行时用了 `rm -rf`。

**纪律**：**删除 = `mv` 到废纸篓**，即使是空目录、即使已经确认无用。
- `rm` 不可逆，废纸篓是用户自己的最后防线；
- 用户说"可以删"，确认的是**删不删**，不是**怎么删**。

---

## 11. 小结：这些坑的共同点

| 坑 | 共同模式 |
|---|---|
| KeepAlive、inode、幽灵键 | **你以为停下了/活着，其实状态不是你以为的** |
| 软链、slug 撞名、测试数据 | **问题不在你盯着的地方** |
| venv、commit、rm | **不可逆操作** |

→ 对应的三条纪律：**先验证再假设、清单化查盲区、不可逆操作必留退路**。