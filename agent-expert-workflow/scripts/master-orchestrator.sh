#!/bin/bash
#═══════════════════════════════════════════════════════════
# master-orchestrator.sh — 自反馈自纠错自进化主控 v4.1
# 来源: OpenAI SDK run_loop + Claude Code nO主循环
#═══════════════════════════════════════════════════════════
set -euo pipefail
VERSION="4.1.0"

WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}"
TASKS_DIR="$WORKSPACE/tasks"
LEARNINGS_DIR="$WORKSPACE/.learnings"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="$WORKSPACE/.orchestrator-state.json"
LOG_FILE="$WORKSPACE/.orchestrator.log"
LOCK_DIR="$WORKSPACE/.locks"

mkdir -p "$TASKS_DIR" "$LEARNINGS_DIR" "$LOCK_DIR" "$(dirname "$LOG_FILE")"

# ─── 文件锁 ───
acquire_lock() {
  local lockfile="$LOCK_DIR/${1}.lock"
  local i=0
  while [ $i -lt 30 ]; do
    if (set -C; echo $$ > "$lockfile") 2>/dev/null; then
      trap "rm -f '$lockfile'" EXIT
      return 0
    fi
    sleep 1; i=$((i + 1))
  done
  return 1
}

release_lock() { rm -f "$LOCK_DIR/${1}.lock"; }

# ─── 日志 ───
log() { echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
log_ok() { log "✅ $1"; }
log_warn() { log "⚠️ $1"; }
log_err() { log "❌ $1"; }
log_info() { log "ℹ️ $1"; }

# ─── 初始化状态 ───
if [ ! -f "$STATE_FILE" ]; then
  echo '{"heartbeat_count":0,"tasks_completed":0,"errors_fixed":0,"version":"'"$VERSION"'"}' > "$STATE_FILE"
fi

HEARTBEAT_COUNT=$(jq -r '.heartbeat_count // 0' "$STATE_FILE" 2>/dev/null || echo 0)
HEARTBEAT_COUNT=$((HEARTBEAT_COUNT + 1))
jq --argjson c "$HEARTBEAT_COUNT" --arg v "$VERSION" '.heartbeat_count = $c | .version = $v' "$STATE_FILE" > "/tmp/orc-$$".json 2>/dev/null && mv "/tmp/orc-$$".json "$STATE_FILE"

log_info "═══ 心跳 #$HEARTBEAT_COUNT (v$VERSION) ═══"

# 获取锁（防止并发）
if ! acquire_lock "orchestrator"; then
  log_warn "另一个实例正在运行，跳过本次心跳"
  echo "HEARTBEAT_OK"
  exit 0
fi

# ─── 查找活跃任务 ───
find_active_tasks() {
  find "$TASKS_DIR" -maxdepth 2 -name "task.json" -exec sh -c '
    for f; do
      state=$(jq -r ".state" "$f" 2>/dev/null || echo "")
      case "$state" in
        in_progress|planning|paused) echo "$f" ;;
      esac
    done
  ' _ {} +
}

ACTIVE_TASKS=$(find_active_tasks || true)

if [ -z "$ACTIVE_TASKS" ]; then
  log_info "没有活跃任务"
  MOD=$((HEARTBEAT_COUNT % 4))
  if [ "$MOD" -eq 0 ]; then
    log_info "执行自主进化..."
    timeout 60 bash "$SCRIPT_DIR/evolve.sh" 2>&1 | tee -a "$LOG_FILE" || true
  fi
  release_lock "orchestrator"
  echo "HEARTBEAT_OK"
  exit 0
fi

# ─── 处理每个活跃任务 ───
HAS_ALERT=false
for TASK_FILE in $ACTIVE_TASKS; do
  TASK_DIR=$(dirname "$TASK_FILE")
  TASK_ID=$(jq -r '.id' "$TASK_FILE" 2>/dev/null || echo "unknown")
  TASK_TITLE=$(jq -r '.title' "$TASK_FILE" 2>/dev/null || echo "unknown")
  TASK_STATE=$(jq -r '.state' "$TASK_FILE" 2>/dev/null || echo "unknown")
  TRACE_FILE="$TASK_DIR/stuck-trace.jsonl"

  log_info "━━━ $TASK_TITLE [$TASK_STATE] ━━━"

  # 恢复 paused 任务
  if [ "$TASK_STATE" = "paused" ]; then
    PAUSE_REASON=$(jq -r '.pause_reason // "unknown"' "$TASK_FILE" 2>/dev/null)
    case "$PAUSE_REASON" in
      max_iterations)
        OLD=$(jq -r '.max_iterations' "$TASK_FILE" 2>/dev/null || echo 50)
        NEW=$((OLD + 25))
        jq --argjson m "$NEW" '.max_iterations = $m | .state = "in_progress" | del(.pause_reason)' "$TASK_FILE" > "/tmp/t-$$".json 2>/dev/null && mv "/tmp/t-$$".json "$TASK_FILE"
        log_warn "迭代上限 $OLD→$NEW，恢复执行"
        ;;
      time_window_exceeded)
        log_warn "时间窗口已过，等待用户设置"
        continue
        ;;
      stuck_detected)
        STUCK=$(jq -r '.stuck_count // 0' "$TASK_FILE" 2>/dev/null || echo 0)
        if [ "$STUCK" -ge 3 ]; then
          log_err "连续卡死 $STUCK 次，标记 blocked"
          jq '.state = "blocked"' "$TASK_FILE" > "/tmp/t-$$".json 2>/dev/null && mv "/tmp/t-$$".json "$TASK_FILE"
          HAS_ALERT=true
          continue
        fi
        jq '.stuck_count = 0 | .state = "in_progress" | del(.pause_reason)' "$TASK_FILE" > "/tmp/t-$$".json 2>/dev/null && mv "/tmp/t-$$".json "$TASK_FILE"
        log_warn "重置卡死计数，恢复执行"
        ;;
      *)
        jq '.state = "in_progress" | del(.pause_reason)' "$TASK_FILE" > "/tmp/t-$$".json 2>/dev/null && mv "/tmp/t-$$".json "$TASK_FILE"
        ;;
    esac
  fi

  # 执行 task-loop（带超时）
  LOOP_OUT=$(timeout 30 bash "$SCRIPT_DIR/task-loop.sh" "$TASK_DIR" 2>&1) || true
  echo "$LOOP_OUT" | tail -3 | tee -a "$LOG_FILE"

  # Watchdog 检测
  MAX_ITER=$(jq -r '.max_iterations // 50' "$TASK_FILE" 2>/dev/null || echo 50)
  if [ -f "$TRACE_FILE" ] && [ "$(wc -l < "$TRACE_FILE" | tr -d ' ')" -gt 0 ]; then
    WD_OUT=$(timeout 10 bash "$SCRIPT_DIR/watchdog.sh" "$TRACE_FILE" "$MAX_ITER" 2>&1) || {
      log_err "Watchdog: $(echo "$WD_OUT" | head -1)"
      STUCK=$(jq -r '.stuck_count // 0' "$TASK_FILE" 2>/dev/null || echo 0)
      STUCK=$((STUCK + 1))
      jq --argjson s "$STUCK" '.stuck_count = $s | .state = "paused" | .pause_reason = "stuck_detected"' "$TASK_FILE" > "/tmp/t-$$".json 2>/dev/null && mv "/tmp/t-$$".json "$TASK_FILE"

      # 学习
      echo "" >> "$LEARNINGS_DIR/ERRORS.md"
      echo "### $(date '+%Y-%m-%d %H:%M') - 卡死 - $TASK_ID" >> "$LEARNINGS_DIR/ERRORS.md"
      echo "- $(echo "$WD_OUT" | head -1)" >> "$LEARNINGS_DIR/ERRORS.md"

      # 自动纠错
      timeout 15 bash "$SCRIPT_DIR/self-correct.sh" "$TASK_DIR" stuck "$WD_OUT" 2>&1 | tee -a "$LOG_FILE" || true

      if [ "$STUCK" -ge 3 ]; then
        jq '.state = "blocked"' "$TASK_FILE" > "/tmp/t-$$".json 2>/dev/null && mv "/tmp/t-$$".json "$TASK_FILE"
        HAS_ALERT=true
      fi
      continue
    }
  fi

  # 完成检查
  NEW_STATE=$(jq -r '.state' "$TASK_FILE" 2>/dev/null || echo "")
  if [ "$NEW_STATE" = "completed" ]; then
    log_ok "任务完成: $TASK_TITLE"
    COMPLETED=$(jq -r '.tasks_completed // 0' "$STATE_FILE" 2>/dev/null || echo 0)
    COMPLETED=$((COMPLETED + 1))
    jq --argjson t "$COMPLETED" '.tasks_completed = $t' "$STATE_FILE" > "/tmp/orc-$$".json 2>/dev/null && mv "/tmp/orc-$$".json "$STATE_FILE"

    # 完成报告
    cat > "$TASK_DIR/completion-report.md" << EOF
# 完成报告: $TASK_TITLE
- ID: $TASK_ID | 时间: $(date -Iseconds)
- 迭代: $(jq -r '.current_iteration // 0' "$TASK_FILE" 2>/dev/null)
- 子任务: $(jq '[.subtasks[]? | select(.state == "completed")] | length' "$TASK_FILE" 2>/dev/null)/$(jq '.subtasks | length' "$TASK_FILE" 2>/dev/null)
EOF
  fi

  # 错误学习
  ERROR_COUNT=$(jq '.errors | length' "$TASK_FILE" 2>/dev/null || echo 0)
  if [ "$ERROR_COUNT" -gt 0 ]; then
    LAST_ERR=$(jq -r '.errors[-1]' "$TASK_FILE" 2>/dev/null || echo "")
    [ -n "$LAST_ERR" ] && [ "$LAST_ERR" != "null" ] && {
      echo "" >> "$LEARNINGS_DIR/ERRORS.md"
      echo "### $(date '+%Y-%m-%d %H:%M') - 执行错误 - $TASK_ID" >> "$LEARNINGS_DIR/ERRORS.md"
      echo "- $LAST_ERR" >> "$LEARNINGS_DIR/ERRORS.md"
    }
  fi
done

# ─── 自主进化 ───
if [ $((HEARTBEAT_COUNT % 4)) -eq 0 ]; then
  log_info "执行自主进化..."
  timeout 60 bash "$SCRIPT_DIR/evolve.sh" 2>&1 | tee -a "$LOG_FILE" || true
fi

# ─── 状态报告 ───
ACTIVE_COUNT=$(echo "$ACTIVE_TASKS" | wc -l | tr -d ' ')
log_info "📊 活跃=$ACTIVE_COUNT 完成=$(jq -r '.tasks_completed' "$STATE_FILE" 2>/dev/null) 心跳=$HEARTBEAT_COUNT"

release_lock "orchestrator"

# ─── HEARTBEAT 输出 ───
BLOCKED=$(find "$TASKS_DIR" -maxdepth 2 -name "task.json" -exec jq -r '.state' {} \; 2>/dev/null | grep -c blocked || echo 0)
if [ "$BLOCKED" -gt 0 ] || [ "$HAS_ALERT" = true ]; then
  echo "⚠️ ALERT: $BLOCKED 个任务阻塞"
else
  echo "HEARTBEAT_OK"
fi
