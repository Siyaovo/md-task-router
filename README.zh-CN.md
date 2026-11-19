# Markdown Task Router（中文说明）

[English](README.md) · 中文

一个很小、不依赖会话的运行时：把一个 Markdown 文件变成 Agent 的控制台。

> 你改 `task-board.md`，监听器发现变化；由 LLM 组成的决策层把 `ready`
> 状态的任务派给子 Agent 并行执行，再把结果写回看板。卡死的任务会自动恢复，
> 失败的会重试，最终失败的写进死信队列。

所有状态都是放在 git 目录里的纯文本。没有数据库，不绑定任何平台。

**一句话说它能干什么：** 你在一个 Markdown 文件里写任务卡，把 `Who` 写成 Claude、`Status` 写成 `ready`，保存。后台的 Claude 会自己接手，做完把结果写回卡片，再把卡改成 `done`。你不用开终端，也不用守着。

---

## 为什么这样设计

- **用 Markdown 当控制台。** 任务就是你本来就在编辑的那个文件里的一张张卡片。状态跟着 git 走，不用再去另一个看板界面里重复录一遍。
- **用有类型的状态机，不用随手写的状态。** 像 `blocked:human:send-brief`、`running:agent-42:2026-04-21T10:15Z` 这样的状态，是一套给 LLM 推理用的小协议，它不用去猜字面意思，可以直接判断依赖链、时间戳是否过期、有没有死锁。
- **只有一个写入者。** 只有主 Claude 会写 `task-board.md`，子 Agent 只负责执行并返回结构化结果。这样就避开了一整类并发写冲突，也不需要分布式锁。
- **静默等待。** 编辑器保存一次，常常会连着触发 5–10 次文件变化。运行器会等文件连续 30 秒没人改动再开始，免得和正在编辑的人抢着写。
- **不依赖会话。** 在 macOS 上由 `launchd` 运行（Linux 用 `systemd` 同理，见下文「移植到 Linux」），和你开没开终端、开没开 Claude Code 都没关系。

---

## 架构

```
编辑 task-board.md
        ↓
fswatch（2 秒防抖）
        ↓
run-task-check.sh
    ↓ 用 mkdir 拿原子锁
    ↓ 等 task-board.md 连续 30 秒没人改
    ↓ 无会话调用 `claude -p /task-check`
        ↓
Claude Code 执行 task-check skill
    ↓ 清理超过 30 分钟的 `running:*`（视为卡死）
    ↓ 依赖已完成的 `blocked:task:X` 自动解锁
    ↓ 按依赖把 `ready` 任务分批
    ↓ 每批最多并行 3 个子 Agent
    ↓ 失败最多重试 2 次，仍失败进死信队列
    ↓ 结果写回 task-board.md（只有一个写入者）
    ↓ 结构化事件追加到 events.jsonl
```

### 五层结构

| 层 | 负责什么 | 用什么实现 |
|---|---|---|
| L5 · 控制台 | 人和 LLM 看同一份状态 | `task-board.md` |
| L4 · 调度 | 文件变化触发 + 每小时兜底 | `fswatch` + `launchd` |
| L3 · 执行 | 无状态的一次性 LLM 调用 | `bash` + `claude -p --no-session-persistence` |
| L2 · 决策 | 按状态机分派、重试、死信 | `task-check` skill（LLM） |
| L1 · 状态与审计 | 只追加的事件日志 + 死信队列 | `events.jsonl` + `deadletter/` |

---

## 需要什么

- **macOS**，装好 Homebrew（Linux 见下文）
- **`fswatch`**：`brew install fswatch`
- **[Claude Code 命令行](https://docs.claude.com/en/docs/claude-code)**，已经在终端里用 `claude` 登录过（需要 Claude Pro 或 Max 订阅）
- 一个文件夹，用来放 `task-board.md` 和 Claude 产出的文件（最好是 git 仓库，方便撤销）

---

## 安装

```bash
# 1. 克隆仓库
git clone https://github.com/Siyaovo/md-task-router.git ~/code/md-task-router
cd ~/code/md-task-router

# 2. 安装 fswatch
brew install fswatch

# 3. 让 WORKSPACE_ROOT 指向放 task-board.md 的文件夹
export WORKSPACE_ROOT=~/notes
mkdir -p "$WORKSPACE_ROOT"
#    还没有看板的话，复制示例看板过去（已经有了就跳过这一行）
cp sample/task-board.md "$WORKSPACE_ROOT/"

# 4.（可选）给 launchd 任务起自己的标签前缀
#    默认是 io.github.local.md-task-router
export LABEL_PREFIX=io.github.yourusername.md-task-router

# 5. 把 task-check skill 装进 Claude Code
mkdir -p ~/.claude/skills/task-check
cp skill/SKILL.md ~/.claude/skills/task-check/SKILL.md

# 6. 给后台运行配一个长期登录（只做一次）
#    普通的 claude 登录会过期，后台没法自己刷新，几周后就会开始失败
claude setup-token          # 在浏览器里确认，终端会打印一个令牌
security add-generic-password -U -a "$USER" -s claude-headless-token -w
#                           # 在提示处粘贴令牌（不会显示出来）

# 7. 生成并加载 launchd 任务
bash bin/install.sh
```

令牌只存在你的钥匙串里。`run-task-check.sh` 每次运行时去钥匙串里读，不用写进任何文件或环境变量。

`install.sh` 会自动找到 `claude` 和 `fswatch` 装在哪里，并把 `WORKSPACE_ROOT` 记下来。之后打开新的终端，直接在仓库目录里运行 `bin/` 下的命令就行，不用再 export 一遍。

如果这个文件夹是 git 仓库，建议在它的 `.gitignore` 里加一行 `.task-router/`，运行日志就不会混进你自己的提交。

### 装好后先跑通一次

1. 打开 `$WORKSPACE_ROOT/task-board.md`，在「To do」下面加一张测试卡：

   ```markdown
   ## [TASK-100] 测试一下
   - **Who**: Claude
   - **Est**: —
   - **Type**: simple
   - **Priority**: P1 · #test · @output
   - **Status**: ready
   - **Measure**: 在 hello.md 里写一句「任务路由跑通了」
   ```

2. 保存，然后等大约一分钟（要先等 30 秒没人改动，再加上 Claude 干活的时间）。
3. 在仓库目录里运行 `bash bin/status.sh`。跑通的话，`hello.md` 已经生成，这张卡变成了 `done`，`events.jsonl` 最后一行是 `completed`。
4. 没反应的话，先看 `$WORKSPACE_ROOT/.task-router/state/launchd-runner.log`，再看下文「事件与排查」。

---

## 日常使用

```bash
# 看当前状态：在跑什么、最近的事件、看板各状态的数量
bash bin/status.sh

# 暂停自动执行（比如你自己正在大改这个文件夹）
bash bin/auto-off.sh

# 恢复
bash bin/auto-on.sh

# 手动跑一次（改了 skill 之后测试用）
bash bin/run-task-check.sh manual

# 完全卸载 launchd 任务
bash bin/uninstall.sh

# 冒烟测试（检查 fswatch、监听器、运行器，不会调用 Claude）
bash bin/smoke-test.sh
```

### 写一张任务卡

在 `task-board.md` 里加一张卡：

```markdown
## [TASK-042] 总结昨天的会议记录

- **Who**: Claude
- **Est**: —
- **Type**: simple
- **Priority**: P1 · #notes · @output
- **Status**: ready
- **Measure**: 在 notes/2026-04-21-meeting.md 顶部写 3 条要点，并把待办单独列成编号清单
```

只有 `Who` 里有 Claude、并且 `Status` 是 `ready` 的卡才会被自动执行；写给人的卡（比如 `Who: 我`）它只会跳过。

保存。监听器发现变化，等文件静默 30 秒后运行器启动。Claude 读看板，找到这张 `ready` 的卡，派给一个子 Agent 去做，写回结果，再把卡改成 `done`。

完整模板、状态写法和每种状态的例子见 [`sample/task-board.md`](sample/task-board.md)。字段名保持英文，内容用中文写没有问题。

### 状态一览

| 状态 | 意思 |
|---|---|
| `ready` | 可以开始，下一次运行会领走 |
| `running:{agent}:{时间}` | 正在做；超过 30 分钟没动静会被当成卡死，重置回 `ready` |
| `blocked:human:{要你做什么}` | 等某个人做一件事 |
| `blocked:task:TASK-XXX` | 等另一张卡完成，完成后自动解锁 |
| `blocked:external:{等什么}` | 等外部的人或信号 |
| `done` | 完成 |
| `cancelled:{原因}` / `failed:{原因}` | 不做了 / 失败了，都要写原因 |

---

## 事件与排查

每一次状态变化都会作为一行 JSON 写进 `$WORKSPACE_ROOT/.task-router/state/events.jsonl`。

```bash
tail -f "$WORKSPACE_ROOT/.task-router/state/events.jsonl"
```

一次完整运行大概是这样：

```json
{"ts":"2026-04-21T10:15:00Z","event":"file_changed_triggered","component":"watcher"}
{"ts":"2026-04-21T10:15:30Z","event":"quiescence_reached","trigger":"fswatch","waited_secs":30,"final_idle_secs":30}
{"ts":"2026-04-21T10:15:30Z","event":"started","trigger":"fswatch"}
{"ts":"2026-04-21T10:15:30Z","event":"task_check_start","version":"v3"}
{"ts":"2026-04-21T10:15:35Z","event":"batch_started","batch_size":1,"task_ids":["TASK-042"]}
{"ts":"2026-04-21T10:15:58Z","event":"task_completed","task_id":"TASK-042","duration_sec":23}
{"ts":"2026-04-21T10:15:58Z","event":"task_check_run","ready":0,"executed":1,"succeeded":1,"retried":0,"deadlettered":0}
{"ts":"2026-04-21T10:15:58Z","event":"completed","trigger":"fswatch","exit_code":0}
```

出问题时，看 `$WORKSPACE_ROOT/.task-router/state/` 下的 `launchd-watcher.log` 和 `launchd-runner.log`，里面是 launchd 托管进程的输出。

### 登录过期

后台运行用的是安装第 6 步存进钥匙串的长期令牌（钥匙串服务名 `claude-headless-token`，可以用 `TOKEN_KEYCHAIN_SERVICE` 改）。如果环境里已经设置了 `CLAUDE_CODE_OAUTH_TOKEN`，就优先用它。

因为登录过期而失败的运行，会记成 `auth_failed`，不会混在普通的 `failed` 里，并且弹一条桌面通知：

```json
{"ts":"2026-09-15T05:48:23Z","event":"auth_failed","trigger":"launchd-hourly","exit_code":1}
```

单独区分这种情况，是因为重试解决不了，必须有人去重新登录。如果混在 `failed` 里，它看起来就像一次偶发错误，定时任务会每小时撞一次墙。我自己就这样连续失败了六个星期才发现。

认证失败后，运行器会退避：只通知一次，之后 6 小时内跳过运行（`AUTH_BACKOFF_SECS`），日志里记 `skipped_auth_backoff`，不再每小时失败一次。修好令牌后，用下面两行立刻恢复：

```bash
rm -f "$WORKSPACE_ROOT/.task-router/state/auth_failed.marker"
bash bin/run-task-check.sh manual
```

### 快照与撤销

如果 `WORKSPACE_ROOT` 是一个 git 仓库，运行器会在每次运行前后各提交一次本地快照（`bin/snapshot.sh`，不会推送）。每次自动运行都会单独成为一个提交：

```bash
git -C "$WORKSPACE_ROOT" log --oneline | head          # 最近几次运行
git -C "$WORKSPACE_ROOT" show --stat <提交号>           # 某次运行改了什么
git -C "$WORKSPACE_ROOT" checkout <提交号> -- task-board.md   # 把一个文件恢复回去
```

文件夹还不是 git 仓库的话，在里面运行一次 `git init` 就行。不想要快照，设置 `SNAPSHOTS=0`。

### 权限

运行器启动 Claude Code 时用的是 `--permission-mode bypassPermissions`，也就是无人值守时它可以直接用任何工具，不会停下来问你。所以：

- `WORKSPACE_ROOT` 只指向你放心让 Agent 修改的文件夹；
- 把这个文件夹放在 git 下，出问题可以用上面的快照退回；
- 你自己在这个文件夹里大改东西时，先用 `bin/auto-off.sh` 暂停。

### 让看板保持简短

`task-check` 每次运行后还会整理看板：卡片的 Notes 最多 3 行，长内容放进单独的文件、卡片里只放链接；做完的卡移到 Done 区；Done 区超过 20 张时，整段归档到 `archive/task-board-archive-YYYY-MM-DD.md`；编号永远不复用。卡片格式（包括记录人需要花多少时间的 `Est` 字段）见 `sample/task-board.md`。

---

## 设计取舍

每一条都写了放弃的方案和具体原因。LLM 驱动的系统里，真正决定它怎么表现的，往往就是这类取舍。

| 决定 | 放弃的方案 | 原因 |
|---|---|---|
| 用 Markdown 当控制台 | Notion / Airtable / Postgres | 任务状态留在用户本来就在编辑的纯文本里，天然有 git 版本记录。缺点是没有字段约束，由有类型的状态机来补。 |
| 有类型的状态协议 | 随手写的状态（「进行中」「等待中」） | 有了协议，LLM 能推理依赖链、死锁和时间戳，而不是去匹配字符串。实际用下来，这是对系统表现影响最大的一点。 |
| 只有一个写入者 | 分布式锁（`flock`、CRDT、追加日志） | Markdown 没有事务。只让一个进程写，就零成本地消掉了一整类并发问题；并行发生在子 Agent 执行这一层。 |
| 30 秒静默等待 | 2 秒防抖 | 人一次保存可能触发 5–10 次事件。没有静默等待，执行器就会和人抢着写。30 秒正好对上人停下来想一想的节奏。 |
| 不用 RAG、不微调 | 检索增强的决策层 | 整张看板通常只有 1–3K token，放得进上下文。决策层需要看到全部进行中的任务才能判断依赖，只检索一部分会漏。 |

---

## 移植到 Linux

只有三处是 macOS 专有的，每一处都有对应的 Linux 方案：

| 部分 | macOS | Linux |
|---|---|---|
| 文件监听 | `fswatch`（Homebrew 安装） | `inotifywait`（`inotify-tools` 包） |
| 服务管理 | `launchd` + `plist` 文件 | `systemd` + `.service` 文件 |
| 脚本（`bin/*.sh`） | bash 3.2+ | bash 4+（把 `stat -f %m` 换成 `stat -c %Y`） |

移植大约两小时：把 plist 模板换成 systemd 服务文件，把监听器里的 `fswatch` 换成 `inotifywait -m -e modify,create,move`，再把 `run-task-check.sh` 和 `status.sh` 里用到的 `stat` 改成 `-c %Y`。状态机、skill、静默等待、死信队列都不用动。

---

## 什么时候不适合用

- **团队协作、操作的人不懂技术。** Coze、Dify、n8n 这类以界面为主、共享状态的工具更合适。
- **需要一个共享的网页界面。** 这个项目刻意把展示留给编辑器或终端。
- **任务量很大（进行中超过 500 个）。** 到这个量级，解析 Markdown 会成为瓶颈。常见的下一步是旁边加一个 SQLite 索引，Markdown 继续当给人看的界面。

---

## 许可

MIT，见 `LICENSE`。
