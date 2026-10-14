# ZCode 项目迁移：记忆与会话修复指南

> 英文副标题：Fixing ZCode Memory & Sessions After Moving or Renaming Projects
>
> 把项目从 `~/Documents/xxx` 搬到 `~/Projects/xxx`（或给项目改名）之后，你可能会发现——
> **代码还在，git 历史还在，但 ZCode 的"项目记忆"读不到了，历史会话也不见了。**
> 这不是 bug，是设计：ZCode 用**项目绝对路径**作为项目身份。本指南讲清楚它怎么工作的，以及怎么安全修复。

**本仓库只讲 ZCode。** 全文内容均来自本机实测：存储结构实证、SQL 实跑、命令实机验证。别的 AI 工具不在范围内。

---

## 适用环境与使用方式

**平台**：所有命令在 **macOS** 实测通过。核心机制与平台无关（路径哈希记忆目录、`project_id` 撞名，任何操作系统上都是同一套逻辑），但执行层用到平台专属工具：

| 本仓库用到 | 其他平台的对应物 |
|---|---|
| `launchctl unload/load` | Windows：`schtasks`；Linux：`systemctl --user` |
| `~/Library/LaunchAgents/*.plist` | Windows：任务计划程序；Linux：`~/.config/systemd/user/` |
| `sed -i ''`（**空引号是 macOS 语法**） | GNU sed 是 `sed -i`（**不加引号**，否则语法报错） |
| `lsof` / `pgrep` / 备份到 `~/Desktop` | Linux 有等价命令；Windows 需换写法 |

> ⚠️ 拿 Linux 版本来照抄，最容易在 `sed -i ''` 这行踩坑——它看起来人畜无害，但在 GNU sed 上直接报错。

**推荐用法：把这个 runbook 交给你的 AI Agent，让它按你的实际环境改写命令后执行。**

本文的真正价值不是那几条命令，而是**一套判断方法**：定位绑定层 → 判断类型 → 换算新标识 → 试点验证 → 查盲区。这个流程在任何平台、任何路径布局下都成立。Agent 需要的不是照抄，而是按第四节「通用侦察步骤」推导出**你这台机器上对应的命令**。

> **给 Agent 的指令模板**：
> 读 `agent-runbook/` 理解流程 → 用 `binding-mechanisms.md` 第四节的通用侦察步骤在你的环境里定位绑定层 → 把命令替换成本平台的等价物 → 先试点 1 个项目并让用户验证 → 再批量。
> **不要假设本文的命令在你的系统上可用。**

---

## 一、先说清楚问题

项目搬家或改名之后，ZCode 里会出现这三种情况：

| 东西 | 搬家后 | 为什么 |
|---|---|---|
| 代码、依赖、git 历史 | ✅ 完好 | 都在项目目录里 |
| **项目记忆**（AI 记住的项目背景、偏好、教训） | ❌ 读不到 | 记忆目录名 = `项目名-sha256(路径)[:16]`，**路径一变哈希就变** |
| **历史会话**（你与 AI 的对话记录） | ✅ 文件没丢<br>❌ 但列表里看不到 | 会话按 ID 存；但归属工作区的标签写着旧路径 |

**关键认知：会话内容永远不丢，只是"找不到"。** 所以修复是安全的——最坏情况可以回滚。

**一句话概括要修的东西**：

| | 位置 | 动作 |
|---|---|---|
| 🔧 记忆 | `~/.zcode/cli/memories/projects/<名字>-<哈希>/` | 改目录名的哈希部分 |
| 🔧 会话归属 | `~/.zcode/cli/db/db.sqlite` 的 `session` 表 | 改 `directory` + `project_id` |
| 🔧 任务/自动化 | `~/.zcode/cli/db/tasks-index.sqlite` | 同上（7 张表按路径关联） |
| ❌ 会话内容 | `~/.zcode/cli/rollout/*.jsonl`、`session_entry` 表 | **不要动** |

## 二、核心方法论：三步走

```
第 1 步  识别绑定层     这个工具把"项目身份"存在哪？（目录名？数据库？配置文件？）
   ↓
第 2 步  规划           算出新标识，先改 1 个项目试点，人工验证
   ↓
第 3 步  批量 + 查盲区  批量执行，然后用清单逐项扫"改名/搬家会破坏的东西"
```

大部分人只做了第 3 步的一半（改记忆目录名），然后发现还有一堆东西坏了——因为**盲区在项目外面**。这份指南的第 3 步清单（7 项）就是为此而来。

## 三、为什么这个仓库值得存在

ZCode 是少数把**两套项目标识**同时用起来的工具：记忆目录名里带路径哈希，会话表里还有一个有损的 `project_id`。两者都会因路径变化而失联，其中 `project_id` **会撞名**（两个无关项目共享同一个值）——用错会导致会话被静默合并。

更关键的是：修复它需要**改目录名 + 改数据库 + 停软件 + 备份**四件事同时做，其中任何一步做错都不会立刻报错。这套流程此前没有系统记录，本仓库把它沉淀下来。

**覆盖范围**：绑定机制实证、迁移检查清单、踩坑实录、以及给 AI Agent 的分阶段执行手册。

## 四、ZCode 要改的三处

| # | 改什么 | 在哪 | 怎么改 |
|---|---|---|---|
| 1 | **记忆目录名** | `~/.zcode/cli/memories/projects/` | `mv <名字>-<旧哈希> <名字>-<新哈希>`，新哈希 = `sha256(新路径)[:16]` |
| 2 | **会话归属** | `db.sqlite` → `session.directory` | `UPDATE session SET directory='新路径' WHERE directory='旧路径'` |
| 3 | **会话分组键** | `db.sqlite` → `session.project_id` | 同一条 UPDATE 里设为目标工作区的锚定值 |

> ⚠️ **`project_id` 绝不能当 WHERE 条件**——它是有损 slug，两个无关项目会撞名，误用它会静默合并两个项目的会话。详见 [`docs/binding-mechanisms.md`](docs/binding-mechanisms.md) 的高危警告。

**完整机制细节**（哈希净化规则、project_id 派生、`project_id` 撞名实测证据、幽灵目录）见 [`docs/binding-mechanisms.md`](docs/binding-mechanisms.md)。

## 五、最重要的 5 句话（读完就能避开大部分坑）

1. **先查盲区再动手**——项目内的引用你查得再细也查不到 `~/.agents/skills/` 里的软链和服务配置。
2. **`kill` 进程 ≠ 停服务**——带 `KeepAlive` 的 launchd 服务会立刻被拉回来。必须 `launchctl unload`。
3. **`project_id` 会撞名**——两个无关项目可能共享同一个值。**永远用 `directory` 精确匹配，绝不用 `project_id` 当 WHERE 条件**。
4. **改前一定先 commit**——未提交的工作目录内容一旦丢了，git 也救不回来。
5. **会话内容永远不用动**——只改"索引/标签"，风险可控。

## 六、快速开始

- **你是人类用户，只想搞懂** → 读本文件 + [`docs/pitfalls.md`](docs/pitfalls.md)（踩坑实录最有意思）
- **你是人类用户，准备动手** → 读本文件 + [`docs/checklist.md`](docs/checklist.md)（打勾清单）+ 实战案例
- **你是 AI Agent，接到了这个任务** → **直接读 [`agent-runbook/`](agent-runbook/README.md)**，那是一份自包含的执行手册，你不需要读其他文档

## 七、目录导航

```
├── README.md                    ← 你在这里（面向人类）
├── docs/
│   ├── binding-mechanisms.md    ← ZCode 绑定机制详解（核心知识）
│   ├── checklist.md             ← 7 项盲区清单（可打勾）
│   ├── pitfalls.md              ← 实战踩坑记录（最有价值的部分）
│   └── case-study.md            ← 一次真实迁移的全过程与数据
└── agent-runbook/               ← 给 AI Agent 的执行手册（自包含）
    ├── README.md                ← 总纲：怎么用这份手册
    ├── phase-1-inventory.md     ← 阶段 1：侦察与规划
    ├── phase-2-memory.md        ← 阶段 2：记忆迁移（文件层，低风险）
    ├── phase-3-session.md       ← 阶段 3：会话迁移（数据库层，需停服务）
    └── rollback.md              ← 回滚手册（任何阶段不满意都用）
```

## 八、这份指南刻意没做什么

- **没有自动迁移脚本**。ZCode 升级后存储布局可能变，写死的脚本会立刻过时并制造事故。给的是**机制 + 清单**，让 Agent（或你）现场判断。
- **不覆盖其它 AI 工具**。若你在其它工具上也踩到同类问题，可自行套用第四节的方法，但本仓库不提供它们的结论（未实测）。

## 九、许可

MIT，见 [LICENSE](LICENSE)。