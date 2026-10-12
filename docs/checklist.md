# 迁移检查清单（7 项盲区）

> 每次批量改名/搬家后逐项过一遍。**每一项都曾经真的坏过。**
> 建议复制到你的迁移笔记里打勾。

---

## 搬/改之前

- [ ] **0-1 未提交改动先 commit**（有大量改动的仓库尤其重要；不可逆操作没有后悔药）
- [ ] **0-2 记下基线数字**：每个 git 仓库的 `git status --porcelain | wc -l`、每个目录的会话数、服务的 PID/端口。改完要对比"零漂移"。
- [ ] **0-3 备份**：数据库三件套（`.sqlite` + `-wal` + `-shm`）+ 要改的目录

---

## 第 1 项：项目内部的硬编码路径

- [ ] 代码里写死的路径（`grep -rn "旧绝对路径" <项目>`）
- [ ] 文档里的路径引用
- [ ] **区分"会执行的"和"测试数据/注释"**：后者不要改（见 pitfalls #7）
- [ ] venv 的 shebang（在子目录里的注意 `dirname` 陷阱，pitfalls #5）

**快速扫描**：
```bash
grep -rln --exclude-dir={.git,node_modules,venv,.venv,__pycache__,dist,build} "旧绝对路径" <项目>
```

---

## 第 2 项：跨项目引用

- [ ] A 项目引用 B 项目的路径（**双向都要查**：已搬的引留守的、留守的引已搬的）
- [ ] **子目录行**也要算上（当时有人在子目录里开会话/开项目）
- [ ] 别名与便捷脚本里的旧路径

**双向扫描**：
```bash
grep -rln "旧路径A\|旧路径B" <所有相关目录>
```

---

## 第 3 项：软链 ⚠️（最容易漏）

- [ ] 用户级 skill 目录：`~/.agents/skills/`、`~/.zcode/skills/`
- [ ] 项目间软链（A 指向 B）
- [ ] 改名前**先看内容**（中文项目会撞名，pitfalls #3）

```bash
find ~/.agents/skills ~/.zcode/skills \
     -maxdepth 1 -type l ! -exec test -e {} \; -print
```

---

## 第 4 项：后台服务（LaunchAgent / Docker）

- [ ] 扫描指向旧路径的 plist：`grep -l "旧路径" ~/Library/LaunchAgents/*.plist`
- [ ] 运行中的进程：`ps aux | grep <项目关键词>`
- [ ] Docker 容器的 bind mount：`docker ps` + `docker inspect <容器> --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}'`
- [ ] **正确停法**：`launchctl unload`（不是 kill），compose 用相对路径挂载则 `down → 搬 → up` 即可
- [ ] **不要在路径修好之前重启电脑**（旧路径的 plist 会被 launchd 拉起失败重试）

---

## 第 5 项：AI 工具自身资产

- [ ] **ZCode 记忆目录**：算新路径哈希 → `mv` 记忆目录 → 修正记忆内容里的旧路径
- [ ] **ZCode 会话标签**：`db.sqlite` 的 `session` 表（`directory` + `project_id`），需停工具+备份
- [ ] **ZCode 任务库**：`tasks-index.sqlite` 的相关表
- [ ] **ZCode 会话表**：`db.sqlite` 的 `session.directory` + `project_id`（⚠️ `project_id` 不可用于 WHERE）
- [ ] **ZCode 任务表**：`tasks-index.sqlite` 中按路径关联的表
- [ ] **同期使用的其它 AI 工具**：绑定层单独检查，**别假设"都一样"**（本仓库不给它们的具体做法，套用 [`binding-mechanisms.md` 第四节](binding-mechanisms.md) 的通用侦察步骤）

**记忆目录改名**：
```bash
python3 -c "import hashlib; print(hashlib.sha256('新绝对路径'.encode()).hexdigest()[:16])"
mv <名字>-<旧哈希> <名字>-<新哈希>
```
> ⚠️ 名字部分（前缀）来自文件夹名净化规则，改名项目时要一并算，见 [`binding-mechanisms.md` 第 1.2 节](binding-mechanisms.md)

---

## 第 6 项：全局配置与终端

- [ ] 用户级规则文件（如 `~/.zcode/AGENTS.md`）里的旧路径
- [ ] `~/.zshrc` / `.zprofile` 里的 alias、export、PATH 项
- [ ] IDE 的"最近工作区"（VSCode `storage.json`）—— 失效无大碍，重开即可
- [ ] 其它 AI 工具的全局配置（若同期使用）

---

## 第 7 项：残留与清理（收尾）

- [ ] 旧位置是否还有残留（空目录、游离文件）
- [ ] 有没有**孤儿键**：指向已删路径的记忆目录 / slug / 孤儿会话
- [ ] 有没有**幽灵键**：在不存在的路径下开过会话产生的空目录
- [ ] 测试项目/测试目录是否还留着
- [ ] **删除一律走废纸篓**（`mv` 到 `~/.Trash/`），不用 `rm`

---

## 全局验收（三道）

- [ ] **服务**：所有该跑的服务活着且工作目录正确
  ```bash
  ps aux | grep <关键词>; lsof -iTCP:<port> -sTCP:LISTEN
  ```
- [ ] **数据零漂移**：git 改动数、会话总数、目录文件数 与基线一致
- [ ] **功能实测**：挑 1-2 个关键项目真跑一次（跑测试 / 打开项目问 AI "还记得什么" / 调一次 API）

> 最后一道最重要。**全绿的全量测试**比任何 grep 都有说服力（见 pitfalls #7：那次 620 passed 就是靠它发现的"不该改的地方"）。