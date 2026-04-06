# 🚀 Agent Expert Workflow — 架构总览

> 从 Anthropic 工程团队、Claude Code 最佳实践、Ralph Loop 模式、多 Agent 协作系统中提炼的标准化工作流。

---

## 解决了什么问题

| 你的痛点 | 根本原因 | 解决方案 |
|----------|----------|----------|
| MCP 配置老是丢 | 没有持久化的工具记忆 | `.tool-registry.json` + `.mcp-snapshots/` |
| 改代码改出死循环 | 没有迭代上限 + 没有外部验证 | §2 安全编码护栏 + 死循环检测器 |
| 长任务几分钟就放弃 | 没有任务分解 + 没有完成标准 | §3 持久执行引擎 (task-list.json) |
| 不知道怎么进化自己 | 没有错误驱动的学习循环 | §4 自我进化引擎 |

---

## 文件结构

```
~/.openclaw/workspace/
├── HEARTBEAT.md              ← 已更新：加入持久任务检查
├── .tool-registry.json       ← 工具/MCP 登记簿
├── .modification-log.md      ← 代码修改迭代日志（死循环检测）
├── .learnings/
│   ├── LEARNINGS.md          ← 学习记录
│   ├── ERRORS.md             ← 错误日志
│   └── FEATURE_REQUESTS.md   ← 功能需求
├── .mcp-snapshots/           ← MCP 配置快照
└── tasks/
    ├── _template.json        ← 任务模板
    └── YYYYMMDD-HHMMSS-xxx/  ← 具体任务目录
        ├── task-list.json    ← 任务清单（子任务+完成标准）
        └── progress.md       ← 进度日志
```

---

## 核心理念来源

| 理念 | 来源 | 落地形式 |
|------|------|----------|
| 功能列表 + 增量进展 | Anthropic: Effective Harnesses for Long-Running Agents | task-list.json + progress.md |
| 完成信号 + Stop Hook | Ralph Loop（Claude Code 社区） | verificationCriteria + 客观验证 |
| 协调器-工作器 | Anthropic: Multi-Agent Research System | 主任务拆子任务，按优先级执行 |
| CLAUDE.md 上下文维护 | Claude Code Best Practices | AGENTS.md / SOUL.md / TOOLS.md |
| TDD + 验证闭环 | Claude Code Best Practices | 每步修改后验证 |
| 角色边界 | agentSkills Multi-Agent | 子任务明确职责 |
| 错误驱动进化 | Self-Improving Agent Skill | .learnings/ 日志系统 |

---

## 如何使用

### 场景 1：开始一个长时间任务（比如 5:00-7:00）

```
1. 创建 tasks/20260407-050000-xxx/ 目录
2. 从 _template.json 复制并填写 task-list.json
3. 把模糊需求拆成有 verificationCriteria 的子任务
4. 按优先级逐个执行
5. 每完成一个 → 更新 task-list.json + progress.md + git commit
6. 时间不够 → 标记 paused，下次心跳继续
```

### 场景 2：修改代码

```
1. 读取完整文件内容
2. 确认修改目标（一句话）
3. 创建 git 检查点
4. 修改 → 验证 → 修改 → 验证（最多 3 轮）
5. 每轮记录到 .modification-log.md
6. 同一文件同一区域出现 3 次 → 停止，重新分析
```

### 场景 3：MCP 配置丢了

```
1. 查看 .tool-registry.json 中的配置位置
2. 查看 .mcp-snapshots/ 中最近的快照
3. 补回配置
4. 运行 healthCheck 验证
```

### 场景 4：24/7 不间断执行

```
HEARTBEAT.md 已配置为：
- 每次心跳检查是否有活跃任务
- 有 → 继续执行下一个子任务
- 没有 → 检查是否有自主工作可做
- 都没有 → HEARTBEAT_OK

心跳间隔取决于你的 openclaw 配置（通常 30 分钟一次）
```

---

## 下一步

你可以要求我现在就：
1. **创建一个具体任务** — 告诉我你想在 5:00-7:00 做什么，我帮你拆解成 task-list.json
2. **扫描现有 MCP 配置** — 把当前已配置的工具全部登记到 .tool-registry.json
3. **设置 cron 定时任务** — 每 25 分钟触发一次持久任务执行
4. **配置每周自审** — cron 调度每周自动回顾 .learnings/
