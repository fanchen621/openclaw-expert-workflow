#!/bin/bash
# task-loop.sh — 单次任务执行循环 v4.1
# 来源: OpenAI SDK run_loop + Anthropic dual-agent
set -euo pipefail

TASK_DIR="${1:?用法: task-loop.sh <task-dir>}"
TASK_JSON="$TASK_DIR/task.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[ ! -f "$TASK_JSON" ] && { echo "❌ task.json 不存在"; exit 1; }

STATE=$(jq -r '.state' "$TASK_JSON" 2>/dev/null || echo "unknown")
ITERATION=$(jq -r '.current_iteration // 0' "$TASK_JSON" 2>/dev/null || echo 0)
MAX_ITER=$(jq -r '.max_iterations // 50' "$TASK_JSON" 2>/dev/null || echo 50)

echo "═══════════════════════════════════════"
echo "📋 $(jq -r '.title' "$TASK_JSON" 2>/dev/null || echo '?')"
echo "📊 状态=$STATE 迭代=$ITERATION/$MAX_ITER 卡死=$(jq -r '.stuck_count // 0' "$TASK_JSON" 2>/dev/null || echo 0)"
echo "═══════════════════════════════════════"

# 终态检查
case "$STATE" in completed|blocked) echo "✅ 任务 $STATE"; exit 0;; esac

# 硬上限 (OpenAI SDK max_turns)
if [ "$ITERATION" -ge "$MAX_ITER" ]; then
  jq '.state = "paused" | .pause_reason = "max_iterations"' "$TASK_JSON" > "/tmp/tl-$$.json" 2>/dev/null && mv "/tmp/tl-$$.json" "$TASK_JSON"
  echo "⚠️ 达到迭代上限 $MAX_ITER"; exit 0
fi

# 时间窗口 (Codex timeout)
END=$(jq -r '.time_window.end // ""' "$TASK_JSON" 2>/dev/null || echo "")
if [ -n "$END" ] && [[ "$(date -Iseconds)" > "$END" ]]; then
  jq '.state = "paused" | .pause_reason = "time_window_exceeded"' "$TASK_JSON" > "/tmp/tl-$$.json" 2>/dev/null && mv "/tmp/tl-$$.json" "$TASK_JSON"
  echo "⚠️ 时间窗口已过"; exit 0
fi

# Watchdog (OpenHands StuckDetector)
TRACE="$TASK_DIR/stuck-trace.jsonl"
if [ -f "$TRACE" ] && [ "$(wc -l < "$TRACE" | tr -d ' ')" -gt 0 ]; then
  timeout 10 bash "$SCRIPT_DIR/watchdog.sh" "$TRACE" "$MAX_ITER" 2>&1 || {
    jq '.stuck_count += 1' "$TASK_JSON" > "/tmp/tl-$$.json" 2>/dev/null && mv "/tmp/tl-$$.json" "$TASK_JSON"
    echo "🚫 卡死检测"; exit 0
  }
fi

# 选子任务
NEXT=$(jq -r '[.subtasks[]? | select(.state == "pending" or .state == "in_progress")] | sort_by(.priority) | first | .id // "none"' "$TASK_JSON" 2>/dev/null || echo "none")

if [ "$NEXT" = "none" ]; then
  TOTAL=$(jq '.subtasks | length' "$TASK_JSON" 2>/dev/null || echo 0)
  if [ "$TOTAL" -eq 0 ]; then
    jq '.state = "planning"' "$TASK_JSON" > "/tmp/tl-$$.json" 2>/dev/null && mv "/tmp/tl-$$.json" "$TASK_JSON"
    echo "📋 子任务为空，保持 planning"; exit 0
  fi
  BLOCKED=$(jq '[.subtasks[]? | select(.state == "blocked")] | length' "$TASK_JSON" 2>/dev/null || echo 0)
  if [ "$BLOCKED" -gt 0 ]; then
    jq '.state = "blocked"' "$TASK_JSON" > "/tmp/tl-$$.json" 2>/dev/null && mv "/tmp/tl-$$.json" "$TASK_JSON"
    echo "🚫 $BLOCKED 个子任务阻塞"; exit 0
  fi
  jq '.state = "completed" | .completed_at = "'"$(date -Iseconds)"'"' "$TASK_JSON" > "/tmp/tl-$$.json" 2>/dev/null && mv "/tmp/tl-$$.json" "$TASK_JSON"
  echo "🎉 任务完成！"; exit 0
fi

# 重试检查
ATT=$(jq -r --arg id "$NEXT" '.subtasks[] | select(.id == $id) | .attempts' "$TASK_JSON" 2>/dev/null || echo 0)
MAX_A=$(jq -r --arg id "$NEXT" '.subtasks[] | select(.id == $id) | .max_attempts' "$TASK_JSON" 2>/dev/null || echo 3)
if [ "$ATT" -ge "$MAX_A" ]; then
  jq --arg id "$NEXT" '(.subtasks[] | select(.id == $id)) |= (.state = "blocked")' "$TASK_JSON" > "/tmp/tl-$$.json" 2>/dev/null && mv "/tmp/tl-$$.json" "$TASK_JSON"
  echo "🚫 $NEXT 重试 $ATT 次，标记 blocked"
  bash "$0" "$TASK_DIR"; exit $?
fi

# 更新状态
jq --arg id "$NEXT" '(.subtasks[] | select(.id == $id)) |= (.state = "in_progress" | .started_at = (now | todate) | .attempts += 1)' "$TASK_JSON" > "/tmp/tl-$$.json" 2>/dev/null && mv "/tmp/tl-$$.json" "$TASK_JSON"
jq '.current_iteration += 1' "$TASK_JSON" > "/tmp/tl-$$.json" 2>/dev/null && mv "/tmp/tl-$$.json" "$TASK_JSON"

# 输出子任务信息
echo ""
echo "▶ $NEXT (尝试 $((ATT+1))/$MAX_A, 迭代 $((ITERATION+1))/$MAX_ITER)"
jq -r --arg id "$NEXT" '.subtasks[] | select(.id == $id) | .description' "$TASK_JSON" 2>/dev/null
echo ""
echo "验证:"
jq -r --arg id "$NEXT" '.subtasks[] | select(.id == $id) | .verify.criteria' "$TASK_JSON" 2>/dev/null
