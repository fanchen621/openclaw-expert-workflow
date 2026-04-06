---
name: agent-expert-workflow
description: "Expert-grade persistent workflow engine for OpenClaw. Distills proven patterns from Anthropic Engineering, Claude Code best practices, Ralph Loop, and multi-agent orchestration into executable daily workflows. Solves: MCP amnesia, code modification infinite loops, premature task abandonment, and enables 24/7 expert-level autonomous execution."
metadata:
  sources:
    - Anthropic Engineering: Effective Harnesses for Long-Running Agents
    - Anthropic: How We Built Our Multi-Agent Research System
    - Claude Code Best Practices (Anthropic official)
    - Ralph Loop pattern (community)
    - agentSkills multi-agent dev framework
  version: "1.0.0"
  author: distilled-from-top-ai-labs
---

# 🧠 Agent Expert Workflow Engine

> 让 OpenClaw 像顶尖 AI 团队的专家一样工作：知道自己做什么、怎么做、做错了怎么修、做完怎么验证。

---

## 你面对的三个核心问题

| 问题 | 根因 | 本 Skill 的解决方案 |
|------|------|---------------------|
| MCP 配置遗忘 | 缺乏持久化的工具状态记忆 | §1 工具状态登记簿 |
| 代码修改造成死循环 | 缺乏外部验证 + 无迭代上限 | §2 安全编码护栏 |
| 长任务敷衍执行 | 缺乏任务分解 + 进度追踪 + 完成验证 | §3 持久执行引擎 |

---

## 使用方式

每次启动长时间任务前，**先执行本 SKILL.md 的 §3 持久执行引擎**。

日常代码修改时，**遵循 §2 安全编码护栏**。

工具配置变更时，**更新 §1 工具状态登记簿**。

---

## §1 工具状态登记簿 (Tool Registry)

> 解决问题：MCP 配置遗忘

### 原则
每次发现或配置新的 MCP Server、工具、API 集成，**必须立即登记**到以下文件：

**文件路径：** `~/.openclaw/workspace/.tool-registry.json`

### 注册格式

```json
{
  "version": "1.0.0",
  "lastUpdated": "2026-04-06T22:00:00+08:00",
  "tools": [
    {
      "id": "unique-tool-id",
      "name": "人类可读名称",
      "type": "mcp-server | cli-tool | api-integration | skill",
      "category": "data | code | communication | monitoring | other",
      "description": "一句话说明这个工具做什么",
      "configLocation": "配置文件路径，如 ~/.openclaw/openclaw.json 中的 mcp.servers.xxx",
      "dependencies": ["依赖的其他工具或包"],
      "healthCheck": "验证工具可用的命令，如 'curl -s http://localhost:3001/health'",
      "commonErrors": [
        {
          "symptom": "症状描述",
          "cause": "原因分析",
          "fix": "修复步骤"
        }
      ],
      "lastVerified": "2026-04-06",
      "status": "active | broken | unknown"
    }
  ]
}
```

### 操作规程

**发现新工具时：**
1. 读取 `.tool-registry.json`
2. 添加新条目
3. 运行 healthCheck 验证
4. 写回文件

**工具出问题时：**
1. 查 registry 中的 commonErrors
2. 尝试 fix 方案
3. 更新 status 和 lastVerified

**启动新任务时：**
1. 快速扫描 registry 中 status != "broken" 的工具
2. 对关键工具运行 healthCheck

---

## §2 安全编码护栏 (Safe Code Modification)

> 解决问题：代码修改造成死循环

### 核心规则：修改前 → 修改中 → 修改后 三段式

#### 修改前 (Pre-Flight Checklist)

- [ ] **读取目标文件完整内容**（不要猜测）
- [ ] **理解修改的影响范围**（哪些文件会受影响）
- [ ] **设置迭代上限**（默认 3 轮修改，每轮必须有可验证的进步）
- [ ] **创建检查点**（`git stash` 或 `git commit -m "checkpoint: before [task]"`）

#### 修改中 (During Modification)

- [ ] **一次只改一个东西**（不要同时改多个文件多个逻辑）
- [ ] **每改一步就验证**（运行测试/编译/语法检查）
- [ ] **检测重复修改**：如果同一行代码被改了超过 2 次，**立即停止**，重新分析问题
- [ ] **迭代计数器**：每轮修改在 `.modification-log` 中记录

#### 修改后 (Post-Modification)

- [ ] **运行完整验证**（测试、编译、lint）
- [ ] **diff 审查**（`git diff` 确认改动符合预期）
- [ ] **提交检查点**（`git commit -m "feat/fix: [描述]"`）

### 死循环检测器 (Loop Detector)

**在每次修改代码前，必须执行以下检查：**

```
检查规则：
1. 如果最近 5 次 git diff 中，同一文件同一区域被反复修改 → 红色警报，停止
2. 如果最近 3 次执行结果完全相同 → 红色警报，停止，重新分析
3. 如果修改导致了新的错误（而非修复原有错误） → 黄色警告，回滚上一步
4. 如果迭代次数 >= 3 且问题未解决 → 停止，升级到人工介入或换策略
```

**检测方法：**
```bash
# 检查最近的修改是否在同一区域反复改动
git log --oneline -10
git diff HEAD~1 HEAD --stat

# 如果同一文件出现在最近多次提交中，触发警报
```

### 代码修改决策树

```
需要修改代码？
├── 读取完整文件内容
├── 确认修改目标（一句话说清楚）
├── 设置 max_iterations = 3
├── FOR iteration in 1..max_iterations:
│   ├── 做出修改
│   ├── 运行验证（测试/编译/lint）
│   ├── 验证通过？ → 提交 + 退出循环 ✅
│   ├── 验证失败？ → 记录错误到 .modification-log
│   ├── 检查是否与上次错误相同？
│   │   ├── 是 → 换策略或回滚
│   │   └── 否 → 继续迭代
│   └── iteration == max_iterations？
│       └── 是 → 停止，记录问题，通知用户 ⚠️
└── 提交最终结果
```

---

## §3 持久执行引擎 (Persistent Execution Engine)

> 解决问题：长任务敷衍执行，几分钟就结束

### 核心架构：任务清单 + 进度追踪 + 完成验证

灵感来源：Anthropic Engineering "Effective Harnesses for Long-Running Agents"

### 3.1 任务初始化 (Init Phase)

接到长时间任务时，**不要直接开始做**，先执行初始化：

**Step 1: 创建任务目录**
```bash
mkdir -p ~/.openclaw/workspace/tasks/$(date +%Y%m%d-%H%M%S)-task-name
TASK_DIR=~/.openclaw/workspace/tasks/$(date +%Y%m%d-%H%M%S)-task-name
```

**Step 2: 生成任务清单 (task-list.json)**

将用户的模糊需求拆解为可验证的子任务：

```json
{
  "taskId": "20260406-220000-expert-workflow",
  "title": "任务标题",
  "createdBy": "user-request",
  "createdAt": "2026-04-06T22:00:00+08:00",
  "timeWindow": {
    "start": "2026-04-06T05:00:00+08:00",
    "end": "2026-04-06T07:00:00+08:00",
    "totalMinutes": 120
  },
  "status": "initialized",
  "subtasks": [
    {
      "id": "ST-001",
      "title": "子任务描述",
      "description": "详细说明",
      "priority": 1,
      "estimatedMinutes": 15,
      "verificationCriteria": ["可验证的完成标准1", "标准2"],
      "status": "pending",
      "result": null,
      "startedAt": null,
      "completedAt": null
    }
  ],
  "checkpoints": [],
  "errors": []
}
```

**Step 3: 生成进度日志 (progress.md)**
```markdown
# 任务进度日志

## 任务信息
- 开始时间: 2026-04-06 05:00
- 预计结束: 2026-04-06 07:00
- 总子任务数: 5

## 当前状态
- ✅ 已完成: 0/5
- 🔄 进行中: 无
- ⏳ 待处理: 5

## 执行日志
（每完成一个子任务，追加一条记录）

## 关键发现与学习
（记录执行过程中的发现、踩坑、最佳实践）
```

### 3.2 任务执行循环 (Execution Loop)

**这是核心——每次执行长任务时严格遵循：**

```
WHILE 有未完成的子任务 AND 未到时间上限:
  1. 读取 task-list.json
  2. 选择优先级最高的 status="pending" 子任务
  3. 更新 status → "in_progress"，记录 startedAt
  4. 执行子任务
  5. 对照 verificationCriteria 逐条验证
  6. 所有标准通过？
     → status → "completed"，记录 completedAt 和 result
     → 更新 progress.md
     → git commit -m "完成 ST-XXX: [标题]"
  7. 未通过？
     → 记录失败原因到 errors 数组
     → status → "pending"（重新排队）或 "blocked"（阻塞）
  8. 检查剩余时间，是否足够继续下一个任务
     → 不够 → 更新 status → "paused"，记录断点
  9. 每完成 3 个子任务 → 生成中期汇报
END WHILE

IF 所有子任务完成:
  → status → "completed"
  → 生成最终总结报告
  → 通知用户
```

### 3.3 完成验证 (Completion Verification)

> **核心原则：Agent 不可以自己宣布任务完成。必须有客观验证。**

灵感来源：Ralph Loop 模式

**验证层级：**
1. **自动验证**：测试通过、编译成功、文件存在 → 可信
2. **交叉验证**：用不同方法验证同一结果（如：写了文件后读回来确认）→ 可信
3. **自评验证**：Agent 判断自己做得好不好 → **不可信**，需对照 task-list.json 的 verificationCriteria

**防敷衍机制：**
- 子任务没有 verificationCriteria → 不允许标记 completed
- verificationCriteria 必须是**可客观验证的**（文件存在/测试通过/命令成功），不能是"我觉得做好了"

### 3.4 时间管理 (Time Management)

**在时间窗口内合理分配工作：**

```
总时间 T 分钟
├── 预留 10% 作为缓冲 (T * 0.1)
├── 预留 5% 用于汇报和整理 (T * 0.05)
├── 可用执行时间 = T * 0.85
└── 按优先级分配给子任务：
    ├── P1 任务先分配
    ├── 每个任务分配 estimatedMinutes
    ├── 如果总预估 > 可用时间 → 砍掉低优先级任务
    └── 如果总预估 < 可用时间 → 补充额外优化任务
```

**心跳检查（每 30 分钟）：**
- 当前进度 vs 计划进度
- 是否有阻塞任务需要升级
- 剩余时间是否充足

### 3.5 断点续传 (Resume After Interruption)

任务被中断后（会话结束、重启等），恢复方法：

```
1. 扫描 tasks/ 目录找到 status != "completed" 的任务
2. 读取 task-list.json 和 progress.md
3. 检查最后一个 checkpoint 的 git commit
4. 从 status="pending" 的最高优先级任务继续
5. 如果时间窗口已过 → 通知用户，请求新的时间窗口
```

---

## §4 自我进化引擎 (Self-Evolution)

> 让 OpenClaw 知道如何正确地修复和进化自己

### 4.1 错误驱动进化

**每次出错后，必须执行：**
1. 记录错误到 `.learnings/ERRORS.md`
2. 分析根因（不是症状，是根因）
3. 决定修复层级：
   - **即时修复**：改一行代码能解决 → 立即做
   - **流程修复**：需要改工作方式 → 更新本 SKILL.md 或 AGENTS.md
   - **知识修复**：需要学习新知识 → 更新 TOOLS.md 或 MEMORY.md
   - **架构修复**：需要重构 → 记录到 TODO，等专门的重构时间

### 4.2 定期自我审查

**每周一次（可通过 cron 调度）：**
1. 回顾本周所有错误日志
2. 找出重复出现的错误模式
3. 将高频错误转化为新的防护规则
4. 更新相关 SKILL.md / AGENTS.md / SOUL.md

### 4.3 进化方向指引

**不要盲目进化。遵循优先级：**
1. **可靠性** > 功能性（先保证不犯错，再考虑做更多）
2. **安全性** > 效率（先保证安全，再考虑快）
3. **可维护性** > 创造性（先保证代码可读，再考虑花哨方案）
4. **用户需求** > 自己的想法（先完成用户要的，再优化自己想的）

---

## §5 24/7 持久执行方案

> 让 OpenClaw 能够不间断地执行任务

### 5.1 心跳驱动执行

利用 OpenClaw 的 HEARTBEAT.md 机制：

```markdown
# HEARTBEAT.md

## 持久任务检查
1. 扫描 tasks/ 目录，找到 status="in_progress" 或 "paused" 的任务
2. 如果有 → 读取 task-list.json，继续执行下一个子任务
3. 如果任务已完成 → 生成汇报，status → "completed"
4. 如果没有活跃任务 → HEARTBEAT_OK
```

### 5.2 Cron 驱动执行

对于需要精确定时的任务：

```
cron 任务配置:
- schedule: 在指定时间窗口内每 25 分钟触发一次
- payload: "继续执行 [任务ID] 的下一个子任务"
- sessionTarget: isolated
```

### 5.3 自主工作循环

当没有明确任务时，OpenClaw 可以自主选择工作：
1. 检查 `.learnings/` 中是否有待处理的错误
2. 检查 `.tool-registry.json` 中是否有工具需要验证
3. 检查 MEMORY.md 是否需要整理
4. 检查是否有过期的 memory 文件需要清理
5. 检查代码仓库是否有未提交的改动

---

## §6 MCP 配置持久化方案

> 专门解决 MCP 配置遗忘问题

### 6.1 MCP 快照机制

每次 MCP 配置变更后，执行：

```bash
# 快照当前 MCP 配置
openclaw gateway config.get > ~/.openclaw/workspace/.mcp-snapshots/$(date +%Y%m%d-%H%M%S).json
```

### 6.2 MCP 注册表

在 `.tool-registry.json` 中维护所有 MCP server 的：
- 名称和描述
- 配置位置
- 依赖项
- 健康检查命令
- 常见故障和修复方法

### 6.3 MCP 恢复流程

发现 MCP 配置丢失时：
1. 读取最新的 `.mcp-snapshots/` 快照
2. 对比当前配置
3. 补回缺失的 MCP server 配置
4. 验证每个 server 可用
5. 更新 `.tool-registry.json` 状态

---

## 快速参考卡片

| 场景 | 做什么 |
|------|--------|
| 开始长时间任务 | §3：创建 task-list.json + progress.md |
| 修改代码 | §2：三段式 + 死循环检测 |
| 配置了新工具 | §1：更新 .tool-registry.json |
| 任务中断了 | §3.5：断点续传 |
| 犯了错误 | §4.1：错误驱动进化 |
| MCP 配置丢了 | §6：MCP 恢复流程 |
| 没有明确任务 | §5.3：自主工作循环 |

---

## 附录：设计原则来源

| 原则 | 来源 |
|------|------|
| 功能列表 + 进度追踪 | Anthropic: Effective Harnesses for Long-Running Agents |
| 完成信号 + Stop Hook | Ralph Loop 模式 |
| 协调器-工作器模式 | Anthropic: Multi-Agent Research System |
| CLAUDE.md 维护 | Claude Code Best Practices |
| TDD + 验证闭环 | Claude Code Best Practices |
| 并行工具调用 | Anthropic Multi-Agent 系统 |
| 角色边界 | agentSkills Multi-Agent 规范 |
| 错误日志 + 自我改进 | Self-Improving Agent Skill |
