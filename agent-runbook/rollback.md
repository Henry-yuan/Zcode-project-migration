# 回滚手册

> 任何阶段出问题，第一时间回滚，不要试图"再改一下补救"。

---

## 原则

| 操作类型 | 可逆性 | 回滚方法 |
|---|---|---|
| 文件/目录 `mv` | ✅ 完全可逆 | `mv` 回去 |
| 记忆目录改名 | ✅ 完全可逆 | `mv` 回旧名 |
| venv sed 改 shebang | ✅ 完全可逆 | 反向 sed，或重建 |
| 数据库 UPDATE | ⚠️ 靠备份 | 还原备份文件 |
| **删除** | ⚠️ 靠废纸篓 | 从 `~/.Trash/` 找回 |
| `rm` 删除 | ❌ **不可逆** | 只能靠备份 |

---

## 场景 A：Phase 2 出问题（文件层）

### 搬错了地方
```bash
mv /新路径/项目A /旧路径/项目A     # 搬回去即可
```
### 记忆目录改错了名
```bash
mv ~/.zcode/cli/memories/projects/<改错的> \
   ~/.zcode/cli/memories/projects/<原名>
# 或者从备份恢复
cp -R ~/Desktop/migration-backup-<TS>/<记忆目录名> ~/.zcode/cli/memories/projects/
```
### venv 改坏了
反向替换即可，或重建：
```bash
sed -i '' 's|/新/绝对/路径|/旧/绝对/路径|g' <venv>/bin/*
# 实在不行：重建 venv
python3 -m venv <venv> && <venv>/bin/pip install -r requirements.txt
```
### 记忆目录改错了
```bash
mv ~/.zcode/cli/memories/projects/<改错的> ~/.zcode/cli/memories/projects/<原名>
```

---

## 场景 B：Phase 3 出问题（数据库层）

**立即停止一切操作**，不要尝试"再 UPDATE 一次修正"。

```bash
# 1) 确保工具完全退出
pgrep -fl "ZCode" | grep -v grep      # 应无输出
lsof ~/.zcode/cli/db/db.sqlite 2>/dev/null   # 应无输出

# 2) 还原备份（TS 换成实际目录名）
TS=20260920-041343
cp ~/Desktop/db-backup-$TS/db.sqlite      ~/.zcode/cli/db/db.sqlite
cp ~/Desktop/db-backup-$TS/db.sqlite-wal  ~/.zcode/cli/db/db.sqlite-wal 2>/dev/null
cp ~/Desktop/db-backup-$TS/db.sqlite-shm  ~/.zcode/cli/db/db.sqlite-shm 2>/dev/null
cp ~/Desktop/db-backup-$TS/tasks-index.sqlite* ~/.zcode/cli/db/ 2>/dev/null

# 3) 验证库健康
sqlite3 ~/.zcode/cli/db/db.sqlite "PRAGMA quick_check;"    # 应 ok

# 4) 让用户重新打开工具，确认恢复原状
```

### 情况：只做了部分 UPDATE 就中断了
最坏情况（事务未 COMMIT）：SQLite 自动回滚，数据无损失。
若已 COMMIT：用备份覆盖即可。

---

## 场景 C：误删了文件

### 如果用的是 `mv` 到废纸篓（正确做法）
```bash
ls ~/.Trash/                     # 找回来
mv ~/.Trash/<文件名> /原位置/
```

### 如果用的是 `rm`（不该发生）
**不可逆**。唯一补救：
- 查备份目录 `~/Desktop/migration-backup-*`
- 查 git（已提交的内容可恢复：`git checkout`）
- **未提交的内容无法找回**

---

## 场景 D：服务起不来

```bash
# 看错误日志
tail -50 /tmp/<服务名>.err.log 2>/dev/null
launchctl list | grep <label>

# 常见原因
# 1. plist 里的路径还没改完 → 逐条核对 ProgramArguments
# 2. venv 的 python 路径不对 → 检查 shebang
# 3. 脚本引用的项目路径没改 → grep 旧路径
# 4. 项目目录权限问题 → ls -la 检查

# 应急：改回旧路径起服务，保证不中断
launchctl unload ~/Library/LaunchAgents/<label>.plist
# 把配置改回旧路径（如果项目还能从旧路径访问）
launchctl load ~/Library/LaunchAgents/<label>.plist
```

---

## 场景 E：改完发现"测试挂了"

**先别急着改回去**——判断是不是本来就该挂：

```bash
cd <项目> && <venv>/bin/python -m pytest -q 2>&1 | tail -5
```

- 如果是**路径相关的**失败 → 确实改漏了，补改；
- 如果是**环境类**失败（如代理、缺依赖包）→ 与本次迁移无关，如实说明；
- 如果是**你改测试数据造成的** → 立刻还原那部分（pitfalls #7）。

---

## 回滚后要做的

1. 如实告诉用户发生了什么、损失了什么；
2. 更新你的工作笔记，记录"这个方案哪里不行"；
3. 不要立刻重试同一个方案——先分析失败原因，换思路。