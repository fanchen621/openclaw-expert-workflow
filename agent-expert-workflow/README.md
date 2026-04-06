# 🔬 Expert Agent Workflow Engine v3

> 从 Claude Code 逆向工程 + OpenHands + Cline + OpenAI SDK + Codex + Qwen-Agent 源码中提炼的**可执行自进化工作系统**。

## 架构总览

```
HEARTBEAT/cron
      │
      ▼
┌─────────────────────────────────────────────────────────┐
│                master-orchestrator.sh                    │
│                   (主控入口)                              │
│                                                         │
│  ┌──────────┐    ┌──────────┐    ┌───────────────────┐  │
│  │ 查找活跃  │───→│ 执行循环  │───→│ 卡死检测/自动纠错  │  │
│  │ 任务     │    │ 工作链   │    │                   │  │
│  └──────────┘    └──────────┘    └───────────────────┘  │
│       │               │                    │            │
│       ▼               ▼                    ▼            │
│  ┌──────────┐    ┌──────────┐    ┌───────────────────┐  │
│  │task-init │    │task-loop │    │watchdog +         │  │
│  │复杂度评估 │    │状态机执行 │    │self-correct       │  │
│  └──────────┘    └──────────┘    └───────────────────┘  │
│                                                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │              evolve.sh (每4次心跳)                 │   │
│  │  错误模式分析 → 工具健康检查 → 进度压缩 →         │   │
│  │  Memory整理 → Trace清理 → 防护规则生成            │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

## 脚本清单

| 脚本 | 来源 | 功能 |
|------|------|------|
| `master-orchestrator.sh` | OpenAI SDK run_loop | **主入口**，心跳触发，串联所有工作链 |
| `task-init.sh` | Claude Code XN5 | 任务初始化 + 复杂度评估 (HIGHEST/MIDDLE/BASIC) |
| `task-loop.sh` | OpenAI SDK + Anthropic | 单次执行循环：选子任务→执行→验证→更新状态 |
| `watchdog.sh` | OpenHands StuckDetector | **5场景卡死检测**（重复动作/连续报错/独白/交替循环/上下文溢出） |
| `trace-logger.sh` | Cline loop-detection | 记录每次操作到 stuck-trace.jsonl |
| `self-correct.sh` | Claude Code fallback | **自动纠错**：回滚/换策略/通知用户 |
| `evolve.sh` | Claude Code AU2 + Self-Improving | **自我进化**：错误分析/工具体检/进度压缩/Memory整理 |

## 工作链对应

| 工作链 | 对应脚本 | 核心机制 |
|--------|----------|----------|
| 1. 任务注册 | `task-init.sh` | 复杂度评估→task.json+progress.md |
| 2. 循环守护 | `watchdog.sh` | 5场景卡死检测 (OpenHands StuckDetector) |
| 3. 工具协调 | `evolve.sh` → check_tools | 健康检查+错误计数+自动标记broken |
| 4. 持久执行 | `task-loop.sh` | max_iterations硬上限+时间窗口+状态机 |
| 5. 完成验证 | `task-loop.sh` → verify | 客观验证（命令/文件/测试），不靠自评 |
| 6. 上下文压缩 | `evolve.sh` → compress | progress.md > 200行自动八段式压缩 |
| 7. MCP持久化 | `.tool-registry.json` | 工具登记+健康检查+故障记录 |
| 8. 24/7执行 | `master-orchestrator.sh` | HEARTBEAT.md驱动的自动循环 |
| 9. Agent Loop | `task-loop.sh` | preventContinuation动态终止 |
| 10. 并发调度 | README中说明 | 读并发写串行的策略指引 |
| 11. SubAgent | README中说明 | sessions_spawn并行子任务 |
| 12. 八段压缩 | `evolve.sh` | progress.md自动压缩 |
| 13. 复杂度评估 | `task-init.sh` | HIGHEST/MIDDLE/BASIC/NONE |
| 14. 自动纠错 | `self-correct.sh` | 回滚/换策略/通知用户三步恢复 |
| 15. 自我进化 | `evolve.sh` | 错误分析→防护规则→工具体检→压缩清理 |

## 快速开始

### 1. 初始化任务

```bash
# 简单任务
bash scripts/task-init.sh "修复登录页面的样式问题"

# 有时间窗口的长任务
bash scripts/task-init.sh "重构整个认证模块" --time-start 05:00 --time-end 07:00 --max-iter 100
```

### 2. 配置 HEARTBEAT 自动执行

```markdown
# HEARTBEAT.md
## 活久任务检查
1. bash ~/.openclaw/workspace/agent-expert-workflow/scripts/master-orchestrator.sh
2. 如果输出包含 HEARTBEAT_OK → HEARTBEAT_OK
3. 否则 → 输出执行结果
```

### 3. 手动执行单次循环

```bash
bash scripts/task-loop.sh ~/.openclaw/workspace/tasks/20260407-050000-xxx
```

### 4. 手动纠错

```bash
bash scripts/self-correct.sh ~/.openclaw/workspace/tasks/20260407-050000-xxx stuck "检测到交替循环"
```

## 源码映射

| 工作链 | 来源 | 代码位置 |
|--------|------|----------|
| Agent Loop | **Claude Code 逆向** | `chunks.95.mjs:315-330` nO函数 |
| 工具并发 | **Claude Code 逆向** | `chunks.95.mjs:410-425` mW5函数 |
| SubAgent | **Claude Code 逆向** | `chunks.99.mjs` I2A+KN5 |
| 八段压缩 | **Claude Code 逆向** | `chunks.94.mjs:1780-1850` AU2 |
| 复杂度 | **Claude Code 逆向** | `chunks.99.mjs:2736-2820` XN5/FN5 |
| 5场景卡死 | OpenHands | `controller/stuck.py` StuckDetector |
| 循环检测 | Cline | `core/task/loop-detection.ts` |
| max_turns | OpenAI SDK | `agents/run_internal/run_loop.py` |
| 超时控制 | Codex | `codex-rs/core/src/exec.rs` |
| 错误处理 | Qwen-Agent | `qwen_agent/agent.py` _call_tool |
| 外部验证 | Ralph Loop | verifyCompletion |
| 双Agent | Anthropic | 工程博客 |
