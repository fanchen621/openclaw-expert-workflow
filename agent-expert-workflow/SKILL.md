---
name: expert-agent-workflow
description: "从 OpenHands/Cline/OpenAI-SDK/Codex/Qwen-Agent 源码中提炼的专家级工作链。解决：MCP遗忘、死循环、长任务敷衍。让 OpenClaw 24/7 像真正的工程专家一样工作。"
metadata:
  version: "3.0.0"
  sources:
    - Claude Code (逆向工程): nO主循环/mW5工具分析/I2A SubAgent/AU2压缩/XN5复杂度
    - OpenHands: AgentController + StuckDetector (5种卡死检测)
    - Cline: ToolExecutor + Coordinator + loop-detection
    - OpenAI Agents SDK: Runner.run_loop + guardrails + max_turns
    - OpenAI Codex: Exec timeout + sandbox + output cap
    - Qwen-Agent: Agent._call_tool + tool registry + error handling
    - Ralph Loop: externalized completion + stop hooks
    - Anthropic Engineering: dual-agent + feature list + progress file
---

# 🔬 Expert Agent Workflow Engine v2

> 每个工作链都来自真实源码，能追溯到具体模块。不是概念堆砌，是可以执行的代码级流程。

---

## 架构总览


## Quick Start — 一键启动

```bash
# 1. 初始化长时间任务
bash agent-expert-workflow/scripts/task-init.sh "你的任务描述" --time-start 05:00 --time-end 07:00

# 2. HEARTBEAT 自动循环（已配置在 HEARTBEAT.md）
# 系统自动: 执行→检测卡死→纠错→学习→进化

# 3. 手动执行一次检查
bash agent-expert-workflow/scripts/master-orchestrator.sh

# 4. 查看任务状态
jq .state tasks/*/task.json

# 5. 查看错误日志
cat .learnings/ERRORS.md
```

## 故障排查

| 症状 | 检查 | 修复 |
|------|------|------|
| 任务一直 planning | subtasks 为空 | 手动拆解子任务写入 task.json |
| 任务 paused | pause_reason | max_iterations→自动恢复; time_window→重设 |
| 任务 blocked | stuck_count >= 3 | 分析 stuck-trace.jsonl，手动介入 |
| watchdog 误报 | trace 内容 | 确认是否真循环 |
| evolve 报工具不健康 | healthCheck | 更新 .tool-registry.json |

## 工作链 1: 任务注册与状态机 (Task Registry & State Machine)

> 来源: OpenHands `AgentController.__init__` + `State` + Cline `TaskState`

OpenHands 的 AgentController 初始化时设置 `max_iterations`，Cline 用 `TaskState` 跟踪任务状态。两者的共同点：**状态必须持久化到磁盘，不依赖内存。**

### 任务状态机

```
                    ┌──────────────┐
                    │  user_input  │
                    └──────┬───────┘
                           ↓
                    ┌──────────────┐
               ┌────│  initialized │
               │    └──────┬───────┘
               │           ↓
               │    ┌──────────────┐
               │    │  planning    │ ← 拆解子任务
               │    └──────┬───────┘
               │           ↓
               │    ┌──────────────┐
               │    │  executing   │ ← 执行循环
               │    └──────┬───────┘
               │           ↓
               │    ┌──────────────┐   ┌──────────┐
               │    │  verifying   │──→│ blocked  │
               │    └──────┬───────┘   └──────────┘
               │           ↓                   ↑
               │    ┌──────────────┐           │
               │    │  completed   │     (重试) │
               │    └──────────────┘           │
               │           ↑                   │
               │    ┌──────────────┐───────────┘
               └────│  paused      │
                    └──────────────┘
```

### 实现：创建任务文件

**每次接受长时间任务时，第一步不是做事，而是注册任务。**

```bash
TASK_DIR="$HOME/.openclaw/workspace/tasks/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$TASK_DIR"
```

### task.json 格式

> 来源: Anthropic 工程博客 feature_list.json + OpenHands TaskTrackingAction + Cline FocusChain

```json
{
  "id": "20260406-220000",
  "title": "任务标题",
  "state": "planning",
  "created_at": "2026-04-06T22:00:00+08:00",
  "time_window": {
    "start": "2026-04-06T05:00:00+08:00",
    "end": "2026-04-06T07:00:00+08:00",
    "budget_minutes": 120
  },
  "max_iterations": 50,
  "current_iteration": 0,
  "subtasks": [
    {
      "id": "ST-001",
      "title": "子任务标题",
      "priority": 1,
      "state": "pending",
      "verify": {
        "type": "command | file_exists | test_pass",
        "criteria": "具体的验证命令或条件",
        "expected": "预期结果"
      },
      "result": null,
      "attempts": 0,
      "max_attempts": 3,
      "started_at": null,
      "completed_at": null
    }
  ],
  "checkpoints": [],
  "stuck_count": 0
}
```

**关键设计：**
- `max_iterations`: 来自 OpenHands `AgentController.__init__(iteration_delta=...)` —— 硬上限，到了就必须停
- `verify.type`: 来自 Ralph Loop 的 `verificationCriteria` —— **客观验证，不靠 Agent 自评**
- `max_attempts`: 来自 Cline `loop-detection` —— 单个子任务最多重试 3 次
- `stuck_count`: 来自 OpenHands `StuckDetector` —— 全局卡死计数

---

## 工作链 2: 循环守护 (Loop Watchdog)

> 来源: OpenHands `StuckDetector` 完整 5 场景检测 + Cline `loop-detection.ts` + OpenAI SDK `reset_tool_choice`

这是解决**死循环**的核心。OpenHands 的 StuckDetector 实现了 5 种卡死场景检测，我把它们翻译成 OpenClaw 可执行的流程。

### 场景 1: 同一动作 + 同一结果（重复 4 次）

> 来源: `StuckDetector._is_stuck_repeating_action_observation`

**检测逻辑：**
最近 4 次操作的 action 类型完全相同，且 observation 也完全相同 → 卡死

**OpenClaw 实现：**
```bash
# 每次执行完一个操作后，追加到 stuck-trace.jsonl
# 检查时：
tail -4 ~/.openclaw/workspace/tasks/CURRENT/stuck-trace.jsonl | \
  jq -r '.action + "|" + .result_hash' | \
  sort | uniq -c | sort -rn | head -1
# 如果输出 "4 ..." → 卡死警报
```

### 场景 2: 同一动作 + 连续错误（重复 3 次）

> 来源: `StuckDetector._is_stuck_repeating_action_error`

**检测逻辑：** 同一个 action 连续 3 次产生 ErrorObservation → 卡死

**OpenClaw 实现：**
```bash
# 统计最近 3 条记录
tail -3 stuck-trace.jsonl | jq -c 'select(.success == false)' | wc -l
# 如果 == 3 且 action 相同 → 卡死
```

### 场景 3: Agent 独白（连续 3 条相同自言自语）

> 来源: `StuckDetector._is_stuck_monologue`

**检测逻辑：** Agent 连续 3 次发送完全相同的 MessageAction → 卡死

**OpenClaw 实现：**
```bash
# 提取最近 3 条 agent 输出的消息
tail -3 stuck-trace.jsonl | jq -r '.agent_message' | \
  sort | uniq -c | sort -rn | head -1
# 如果 "3 相同消息" → 卡死
```

### 场景 4: 交替循环（6步模式，A→B→A→B→A→B）

> 来源: `StuckDetector._is_stuck_action_observation_pattern`

**检测逻辑：** 最近 6 个事件形成 A→B→A→B→A→B 模式 → 卡死

**OpenClaw 实现：**
```bash
# 提取最近 6 条 action
tail -6 stuck-trace.jsonl | jq -r '.action'
# 检查 1==3==5 且 2==4==6 → 交替循环
```

### 场景 5: 上下文窗口错误循环（连续 10+ 条上下文溢出）

> 来源: `StuckDetector._is_stuck_context_window_error`

**检测逻辑：** 连续 10 次遇到上下文窗口溢出错误 → 卡死

**OpenClaw 实现：**
```bash
tail -10 stuck-trace.jsonl | jq -c 'select(.error | contains("context"))' | wc -l
# 如果 == 10 → 需要压缩上下文
```

### 综合检测器脚本

```bash
#!/bin/bash
# watchdog.sh — 在每次操作后调用
TRACE_FILE="$1"  # stuck-trace.jsonl 路径
MAX_ITERATIONS=${2:-50}

ITERATION=$(wc -l < "$TRACE_FILE")
if [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
  echo "⚠️ MAX_ITERATIONS ($MAX_ITERATIONS) REACHED"
  echo '{"event":"stuck","type":"max_iterations","count":'$ITERATION'}' >> "$TRACE_FILE"
  exit 1
fi

# 检查场景 1-5（上面的逻辑）
# ... 任一触发则 exit 1
```

### OpenAI SDK 的 `reset_tool_choice` 机制

> 来源: `Agent.reset_tool_choice = True`

OpenAI SDK 默认在每次工具调用后重置 `tool_choice`，防止模型陷入"必须调用工具"的死循环。

**OpenClaw 对应：** 每次工具调用后，在下一轮 prompt 中加入：
```
你可以选择：继续使用工具，或者输出最终结果。不要无意义地重复调用同一个工具。
```

---

## 工作链 3: 工具执行协调器 (Tool Execution Coordinator)

> 来源: Cline `ToolExecutorCoordinator` + `ToolValidator` + Qwen-Agent `_call_tool`

### Cline 的 Coordinator 模式

Cline 用一个中央协调器 `ToolExecutorCoordinator` 管理所有工具的注册、验证和执行：
- 每个工具注册 handler
- 执行前通过 `ToolValidator` 验证
- Plan Mode 下限制某些工具（FILE_NEW, FILE_EDIT 等只能在 Act Mode 使用）

### OpenClaw 对应：工具注册表 + 执行前验证

**`.tool-registry.json` 结构：**

```json
{
  "version": "2.0.0",
  "lastUpdated": "2026-04-06T22:00:00+08:00",
  "tools": [
    {
      "id": "tool-id",
      "name": "可读名称",
      "type": "mcp-server | cli-tool | api-integration",
      "status": "active | broken | unknown",
      "configLocation": "配置路径",
      "healthCheck": "验证命令",
      "dependencies": ["dep1"],
      "maxRetries": 3,
      "timeoutMs": 10000,
      "commonErrors": [
        {
          "pattern": "错误模式（正则）",
          "cause": "原因",
          "fix": "修复命令"
        }
      ],
      "lastVerified": "2026-04-06",
      "usageCount": 0,
      "errorCount": 0,
      "lastError": null
    }
  ]
}
```

### Qwen-Agent 的错误处理模式

> 来源: `Agent._call_tool` 异常捕获

Qwen-Agent 在 `_call_tool` 中捕获所有异常，格式化为：`{type}: {message}\nTraceback:\n{traceback}`

**OpenClaw 对应：** 每次工具调用失败后：
1. 记录完整错误到 `.tool-registry.json` 的 `lastError`
2. 检查 `commonErrors` 中是否有匹配的 pattern
3. 如果有 → 执行 fix 命令
4. 如果没有 → 记录到 `.learnings/ERRORS.md`
5. `errorCount++`，如果连续 3 次失败 → 标记 status = "broken"

### Codex 的超时与输出上限

> 来源: `DEFAULT_EXEC_COMMAND_TIMEOUT_MS = 10_000` + `EXEC_OUTPUT_MAX_BYTES`

Codex 的每个命令都有：
- 超时限制（默认 10 秒）
- 输出大小上限（防止 OOM）
- 沙箱隔离

**OpenClaw 对应：** 每个工具调用时：
- 长命令必须设置超时
- 输出过长时截断并记录
- 危险命令前创建 git checkpoint

---

## 工作链 4: 持久执行循环 (Persistent Execution Loop)

> 来源: OpenAI Agents SDK `Runner.run()` + `run_loop.py` + Anthropic dual-agent architecture

### OpenAI SDK 的 run loop 核心逻辑

```python
# 从 run_loop.py 提取的核心循环：
while True:
    response = model.chat(messages, tools)     # 1. 调用 LLM
    if response.has_final_output:               # 2. 检查是否完成
        return response.final_output
    if response.has_handoff:                    # 3. 检查是否需要交接
        agent = response.handoff_target
        continue
    tool_results = execute_tools(response)      # 4. 执行工具
    messages.extend(tool_results)               # 5. 更新上下文
    if turns >= max_turns:                      # 6. 硬上限
        raise MaxTurnsExceeded()
```

**关键参数：**
- `max_turns` — 默认有硬上限
- `guardrails` — 输入/输出护栏检查
- `tool_use_behavior` — "run_llm_again" | "stop_on_first_tool" | 自定义函数

### OpenClaw 的任务执行循环

**每次心跳或 cron 触发时执行：**

```bash
#!/bin/bash
# task-loop.sh — 任务执行循环

TASK_DIR="$1"
TASK_JSON="$TASK_DIR/task.json"
TRACE_FILE="$TASK_DIR/stuck-trace.jsonl"
PROGRESS_FILE="$TASK_DIR/progress.md"

# 1. 读取当前状态
STATE=$(jq -r '.state' "$TASK_JSON")
ITERATION=$(jq -r '.current_iteration' "$TASK_JSON")
MAX_ITER=$(jq -r '.max_iterations' "$TASK_JSON")

# 2. 硬上限检查 (OpenAI SDK max_turns)
if [ "$ITERATION" -ge "$MAX_ITER" ]; then
  jq '.state = "paused" | .pause_reason = "max_iterations"' "$TASK_JSON" > tmp && mv tmp "$TASK_JSON"
  echo "⚠️ 达到最大迭代次数 $MAX_ITER，暂停任务"
  exit 0
fi

# 3. 时间窗口检查 (Codex timeout)
END_TIME=$(jq -r '.time_window.end' "$TASK_JSON")
NOW=$(date -Iseconds)
if [[ "$NOW" > "$END_TIME" ]]; then
  jq '.state = "paused" | .pause_reason = "time_window_exceeded"' "$TASK_JSON" > tmp && mv tmp "$TASK_JSON"
  echo "⚠️ 时间窗口已过，暂停任务"
  exit 0
fi

# 4. 循环守护检查 (OpenHands StuckDetector)
bash watchdog.sh "$TRACE_FILE" "$MAX_ITER"
if [ $? -ne 0 ]; then
  jq '.state = "blocked" | .stuck_count += 1' "$TASK_JSON" > tmp && mv tmp "$TASK_JSON"
  echo "🚫 检测到卡死，暂停任务"
  exit 0
fi

# 5. 选择下一个子任务
NEXT=$(jq -r '[.subtasks[] | select(.state == "pending")] | sort_by(.priority) | first | .id // "none"' "$TASK_JSON")
if [ "$NEXT" = "none" ]; then
  jq '.state = "completed"' "$TASK_JSON" > tmp && mv tmp "$TASK_JSON"
  echo "✅ 所有子任务完成"
  exit 0
fi

# 6. 更新状态为执行中
jq --arg id "$NEXT" '(.subtasks[] | select(.id == $id)) |= (.state = "in_progress" | .started_at = now | .attempts += 1)' "$TASK_JSON" > tmp && mv tmp "$TASK_JSON"

# 7. 迭代计数 +1
jq '.current_iteration += 1' "$TASK_JSON" > tmp && mv tmp "$TASK_JSON"

echo "🔄 执行子任务 $NEXT (迭代 #$((ITERATION+1))/$MAX_ITER)"
```

### Anthropic 双 Agent 模式的 OpenClaw 实现

> 来源: Anthropic 工程博客 "Effective Harnesses for Long-Running Agents"

**Agent 1 (初始化)** — 只在任务开始时运行一次：
- 将模糊需求拆解为 `task.json` 中的子任务
- 每个子任务写好 `verify` 验证标准
- 生成 `progress.md` 初始模板
- 创建第一个 git checkpoint

**Agent 2 (执行者)** — 每次心跳/cron 运行：
- 读取 `task.json` + `progress.md`
- 选一个 pending 子任务
- 执行 + 验证
- 更新 `task.json` + `progress.md`
- git commit

---

## 工作链 5: 完成验证 (Completion Verification)

> 来源: Ralph Loop `verifyCompletion` + Cline `doesLatestTaskCompletionHaveNewChanges`

### 核心原则：Agent 不可以自己宣布完成

Ralph Loop 的 `verifyCompletion` 是外部函数，不信任 LLM 的自我评估。Cline 有 `doesLatestTaskCompletionHaveNewChanges()` 检查实际代码变更。

### 三级验证

**Level 1 — 命令验证（可信）**
```bash
# 验证类型: test_pass
eval "$TASK.verify.criteria"
# 例如: npm test && echo "PASS" || echo "FAIL"

# 验证类型: file_exists
test -f "$TASK.verify.criteria" && echo "PASS" || echo "FAIL"

# 验证类型: command
eval "$TASK.verify.criteria" 2>&1 | grep -q "$TASK.verify.expected" && echo "PASS" || echo "FAIL"
```

**Level 2 — 差异验证（可信）**
```bash
# 检查是否有实际变更
git diff --stat HEAD~1 HEAD
# 如果没有输出 → 没有实际变更，不能标记 completed
```

**Level 3 — 自评（不可信，仅参考）**
- Agent 自己说"我觉得做好了" → 忽略
- 必须 Level 1 或 Level 2 通过才允许 `state = "completed"`

### 防敷衍规则

```
IF 子任务.attempts >= max_attempts AND verify 未通过:
  → state = "blocked"
  → 记录原因到 errors 数组
  → 通知用户

IF 所有子任务都 completed:
  → 运行最终验证：所有 verify criteria 再跑一遍
  → 全部通过 → state = "completed"，生成汇报
  → 有失败 → 打回对应子任务
```

---

## 工作链 6: 上下文压缩 (Context Condensation)

> 来源: OpenHands `Condenser` + `CondensationAction` + `CondensationRequestTool`

OpenHands 有专门的 `Condenser` 模块处理上下文溢出：
- 当历史太长时，Agent 可以调用 `CondensationRequestTool` 请求压缩
- `Condenser` 会丢弃旧事件，保留摘要
- `forgotten_event_ids` 记录哪些事件被丢弃了

**OpenClaw 对应：**

```bash
# 当上下文接近上限时（比如 progress.md > 5000 行）
# 自动压缩：

# 1. 保留最近的执行日志
tail -100 "$PROGRESS_FILE" > "$PROGRESS_FILE.recent"

# 2. 生成摘要
# (由 Agent 在 prompt 中完成)

# 3. 替换
mv "$PROGRESS_FILE.recent" "$PROGRESS_FILE"
```

### progress.md 的压缩规则

```markdown
# 任务进度日志

## 压缩摘要（自动生成）
- 已完成 12/20 个子任务
- 耗时 45 分钟
- 关键发现：xxx 模式有效，yyy 方法不可行
- 阻塞问题：zzz

## 最近执行日志（保留最后 20 条）
...
```

---

## 工作链 7: MCP 配置持久化

> 来源: Cline `McpHub` + Qwen-Agent `MCPManager` + OpenAI SDK `MCPServer`

### 核心机制：快照 + 自动恢复

```bash
# 1. MCP 配置快照目录
MCP_DIR="$HOME/.openclaw/workspace/.mcp-snapshots"
mkdir -p "$MCP_DIR"

# 2. 每次配置变更后快照
openclaw gateway config.get 2>/dev/null | \
  python3 -c "import sys,json; json.dump(json.load(sys.stdin),sys.stdout,indent=2)" > \
  "$MCP_DIR/$(date +%Y%m%d-%H%M%S).json"

# 3. 恢复时：对比最新快照 vs 当前配置
LATEST=$(ls -t "$MCP_DIR"/*.json 2>/dev/null | head -1)
# diff 对比，补回缺失项
```

---

## 工作链 8: 心跳驱动 24/7 执行

> 来源: OpenClaw HEARTBEAT.md + cron 机制

### HEARTBEAT.md 配置

```markdown
# HEARTBEAT.md

## 1. 活跃任务检查
- 扫描 tasks/ 目录找到 state != "completed" 且 != "paused" 的任务
- 如果有 → 运行 task-loop.sh 继续执行
- 如果没有 → 继续下一步

## 2. 自主工作检查（每 4 次心跳执行 1 次）
- 检查 .learnings/ERRORS.md 是否有未处理的错误
- 检查 .tool-registry.json 中 status="unknown" 的工具并验证
- 检查 MEMORY.md 是否需要整理
- 都没有 → HEARTBEAT_OK
```

---

## 工作链 9: Claude Code Agent Loop (逆向工程)

> 来源: Claude Code 逆向工程 — `nO` 函数 (chunks.95.mjs:315-330)

### 核心：无固定轮数的动态循环

Claude Code 不用固定 `for i in range(N)` 循环，而是用 `preventContinuation` 标志动态决定是否继续。

```
// Claude Code nO 主循环 (逆向重建)
async function* nO(messages, system, tools, ...) {
  let E = false;
  while (E) {
    E = false;
    // 1. 调用 LLM (流式响应 + 中断信号)
    for await (let chunk of llm_chat(...)) {
      yield chunk
    }
    // 2. 提取工具调用
    let toolCalls = extractToolUse(assistantMessages);
    if (!toolCalls.length) return;  // 无工具调用 → 结束

    // 3. 执行工具 (通过 mW5 分析并发安全性)
    for await (let result of executeTools(toolCalls, ...)) {
      yield result
      if (result.type === "system" && result.preventContinuation) return; // 终止信号
    }

    // 4. 递归调用继续循环
    yield* nO([...messages, ...newMessages], ...)
  }
}
```

**终止条件（3 种）：**
1. 用户中断 — yield 检查中断点，实时响应
2. 系统级错误 — 工具执行失败无法重试，模型调用失败无备用
3. 无新信息 — 工具调用结束没有产生状态变化，任务明确完成

**OpenClaw 对应：** HEARTBEAT.md 中的任务循环不应该有固定轮数，而是在每次迭代后检查：
- 是否产生了新的文件变更？（git diff）
- 是否有未完成的子任务？（task.json）
- watchdog 是否检测到卡死？
- 时间窗口是否还在？

## 工作链 10: Claude Code 工具并发调度 (逆向工程)

> 来源: `mW5` 函数 (chunks.95.mjs:410-425) + `gW5=10` 并发限制

### 核心：读并发、写顺序

```javascript
// mW5 工具安全性分析 (逆向重建)
function analyzeConcurrency(toolCalls, context) {
  return toolCalls.reduce((groups, call) => {
    let tool = context.tools.find(t => t.name === call.name);
    let isSafe = tool?.isConcurrencySafe(call.input);  // 只读 = true
    if (isSafe && groups[last]?.isConcurrencySafe)
      groups[last].blocks.push(call);  // 安全工具合并执行
    else
      groups.push({ isConcurrencySafe: isSafe, blocks: [call] });  // 不安全工具单独执行
    return groups;
  }, []);
}
```

**工具分类：**

| 类型 | 并发安全 | 工具 |
|------|---------|------|
| 读操作 | ✅ 并发 | Read, LS, Glob, Grep, WebFetch, WebSearch |
| 写操作 | ❌ 顺序 | Edit, Write, Bash, Delete, Task |

**OpenClaw 对应：** 当 Agent 需要执行多个操作时：
1. 先分析哪些可以并发（读文件、查日志、搜索）
2. 再分析哪些必须串行（写文件、执行命令、修改配置）
3. 读操作先全部完成，再逐个执行写操作

## 工作链 11: Claude Code SubAgent 机制 (逆向工程)

> 来源: `I2A` 函数 (chunks.99.mjs) + `KN5` 结果聚合

### 核心：无状态 SubAgent + LLM 聚合

```javascript
// I2A SubAgent 实例化 (逆向重建)
async function* createSubAgent(task, index, parentContext) {
  let sessionId = generateId();
  let systemPrompt = buildSystemPrompt(parentContext);

  // SubAgent 有独立上下文，但继承工具权限
  let result = await runAgentLoop(task, {
    sessionId,
    systemPrompt,
    tools: parentContext.tools,
    isSubAgent: true
  });

  return {
    agentIndex: index,
    content: result.messages,
    tokens: result.usage.total,
    toolUseCount: result.toolCalls.length
  };
}

// KN5 结果聚合 (用 LLM 合并，不是算法)
function buildSynthesisPrompt(originalTask, agentResults) {
  return `Original task: ${originalTask}

I've assigned multiple agents to tackle this task.
${agentResults.map((r, i) => `== AGENT ${i+1} RESPONSE ==\n${r.content}`).join('\n\n')}

Based on all the information, synthesize a response that:
1. Combines key insights from all agents
2. Resolves any contradictions
3. Presents a unified solution
4. Includes all important details and code examples
5. Is well-structured and complete`;
}
```

**OpenClaw 对应：** 当任务太复杂时，不要硬扛，而是：
1. 将任务拆成 N 个独立子任务
2. 每个子任务用独立的 SubAgent 处理（可用 sessions_spawn）
3. 收集所有结果后，用 LLM 合成最终报告
4. 并行上限 10 个

## 工作链 12: Claude Code 八段式上下文压缩 (逆向工程)

> 来源: `AU2` 函数 (chunks.94.mjs:1780-1850) + 92% 阈值

### 核心：结构化压缩，不是简单截断

Claude Code 在 Token 使用率达到 **92%** 时触发八段式压缩：

```
压缩结构：
1. 用户的主要请求和意图
2. 关键技术概念
3. 相关的文件位置
4. 出现的问题及其解决方案
5. 问题解决的思路方法结果
6. 所有用户消息的完整记录和时间线
7. 待完成的任务和当前工作
8. 下一步计划
```

**OpenClaw 对应：** 当 `progress.md` 或会话上下文过长时：
```markdown
## 压缩摘要（自动生成）
### 1. 核心任务
[用户最初要什么]

### 2. 关键发现
[学到了什么有用的东西]

### 3. 文件地图
[改了哪些文件，为什么]

### 4. 问题与解决
[遇到什么问题，怎么解决的]

### 5. 当前状态
[做到了哪里]

### 6. 待办事项
[还有什么没做]
```

## 工作链 13: Claude Code 复杂度评估 (逆向工程)

> 来源: `XN5` + `FN5` + `WN5` 函数 (chunks.99.mjs:2736-2820)

### 核心：四级复杂度评分决定执行策略

```
HIGHEST (31999分) → 触发多 Agent 并行处理
MIDDLE  (10000分) → 单 Agent + TodoWrite 任务管理
BASIC   (4000分)  → 单 Agent 直接执行
NONE    (0分)     → 简单回复，不需要工具
```

**模式匹配示例：**
- 输入包含 "深入思考"、"全面分析" → HIGHEST
- 输入包含 "帮我写"、"创建一个" → MIDDLE
- 输入包含 "查看"、"读取" → BASIC
- 输入是问候语 → NONE

**OpenClaw 对应：** 收到任务时先评估复杂度：
1. 简单任务（BASIC）→ 直接做，不需要创建 task.json
2. 中等任务（MIDDLE）→ 创建 task.json，单 Agent 逐个执行
3. 复杂任务（HIGHEST）→ 创建 task.json + 拆子任务 + 考虑 SubAgent 并行

---

## 快速参考

| 问题 | 工作链 | 核心机制 |
|------|--------|----------|
| MCP 忘记了 | §7 | .mcp-snapshots/ + 自动对比恢复 |
| 死循环 | §2 | 5 场景检测 + max_iterations 硬上限 |
| 敷衍执行 | §4 + §5 | task.json 状态机 + 客观验证 + max_attempts |
| 上下文溢出 | §6 | 进度日志压缩 + 摘要保留 |
| 工具出错 | §3 | 错误计数 + pattern 匹配 + 自动修复 |
| 24/7 执行 | §8 | HEARTBEAT.md + task-loop.sh |

---

## 附录：源码映射

| 工作链 | 来源代码 | 文件/模块 |
|--------|----------|-----------|
| Agent Loop | **Claude Code 逆向** | `chunks.95.mjs:315-330` — `nO` 主循环函数 |
| 工具并发调度 | **Claude Code 逆向** | `chunks.95.mjs:410-425` — `mW5` 安全分析 |
| SubAgent | **Claude Code 逆向** | `chunks.99.mjs` — `I2A` 实例化 + `KN5` 聚合 |
| 八段式压缩 | **Claude Code 逆向** | `chunks.94.mjs:1780-1850` — `AU2` 压缩函数 |
| 复杂度评估 | **Claude Code 逆向** | `chunks.99.mjs:2736-2820` — `XN5`/`FN5`/`WN5` |
| 任务状态机 | OpenHands | `controller/agent_controller.py` — `AgentController.__init__` |
| 循环守护 | OpenHands | `controller/stuck.py` — `StuckDetector.is_stuck()` 5 场景 |
| 循环守护 | Cline | `core/task/loop-detection.ts` — `checkRepeatedToolCall()` |
| 循环守护 | OpenAI SDK | `agents/agent.py` — `reset_tool_choice = True` |
| 工具协调器 | Cline | `core/task/ToolExecutor.ts` — `ToolExecutorCoordinator` |
| 工具协调器 | Qwen-Agent | `qwen_agent/agent.py` — `Agent._call_tool()` |
| 执行循环 | OpenAI SDK | `agents/run_internal/run_loop.py` — `run_single_turn()` |
| 执行循环 | Anthropic | 工程博客 "Effective Harnesses for Long-Running Agents" |
| 完成验证 | Ralph Loop | `ralph-loop-agent` — `verifyCompletion()` |
| 上下文压缩 | OpenHands | `agenthub/codeact_agent/codeact_agent.py` — `Condenser` |
| 超时控制 | Codex | `codex-rs/core/src/exec.rs` — `DEFAULT_EXEC_COMMAND_TIMEOUT_MS` |
| 输出上限 | Codex | `codex-rs/core/src/exec.rs` — `EXEC_OUTPUT_MAX_BYTES` |
