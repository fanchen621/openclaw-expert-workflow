#!/bin/bash
# self-correct.sh — 自动纠错引擎 v4.1
# 来源: OpenHands recovery + Claude Code fallback + Cline checkpoint
set -euo pipefail

TASK_DIR="${1:?用法: self-correct.sh <task-dir> <error-type> [detail]}"
ERROR_TYPE="${2:?缺少 error-type: stuck|max_iterations|tool_error|verify_failed}"
ERROR_DETAIL="${3:-}"

TASK_JSON="$TASK_DIR/task.json"
TRACE_FILE="$TASK_DIR/stuck-trace.jsonl"
WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}"

log() { echo "[$(date '+%H:%M')] 🔧 $1"; }

TASK_ID=$(jq -r '.id' "$TASK_JSON" 2>/dev/null || echo "?")
STUCK_COUNT=$(jq -r '.stuck_count // 0' "$TASK_JSON" 2>/dev/null || echo 0)

# ─── 策略1: Git回滚 ───
try_rollback() {
  cd "$WORKSPACE" || return 1
  git rev-parse --git-dir >/dev/null 2>&1 || return 1
  local cp; cp=$(git log --oneline --grep="checkpoint:" -1 --format="%H" 2>/dev/null)
  [ -z "$cp" ] && return 1
  log "回滚到 $cp"
  git reset --hard "$cp" --quiet 2>/dev/null || return 1
  [ -f "$TRACE_FILE" ] && > "$TRACE_FILE"
  jq '.stuck_count = 0' "$TASK_JSON" > "/tmp/tc-$$.json" 2>/dev/null && mv "/tmp/tc-$$.json" "$TASK_JSON"
  return 0
}

# ─── 策略2: 换策略重试 ───
try_strategy() {
  log "切换策略重试"
  [ -f "$TRACE_FILE" ] && > "$TRACE_FILE"
  jq '.stuck_count = 0' "$TASK_JSON" > "/tmp/tc-$$.json" 2>/dev/null && mv "/tmp/tc-$$.json" "$TASK_JSON"
  local cur; cur=$(jq -r '[.subtasks[]? | select(.state == "in_progress")] | first | .id // "none"' "$TASK_JSON" 2>/dev/null)
  if [ "$cur" != "none" ]; then
    local p; p=$(jq -r --arg id "$cur" '.subtasks[] | select(.id == $id) | .priority' "$TASK_JSON" 2>/dev/null || echo 1)
    jq --arg id "$cur" --argjson np "$((p + 1))" '(.subtasks[] | select(.id == $id)) |= (.state = "pending" | .priority = $np | .attempts = 0)' "$TASK_JSON" > "/tmp/tc-$$.json" 2>/dev/null && mv "/tmp/tc-$$.json" "$TASK_JSON"
  fi
}

# ─── 策略3: 通知用户 ───
notify_user() {
  log "📢 需要用户介入: $1"
  jq --arg e "$1" '.errors += [$e] | .state = "blocked"' "$TASK_JSON" > "/tmp/tc-$$.json" 2>/dev/null && mv "/tmp/tc-$$.json" "$TASK_JSON"
  echo "" >> "$WORKSPACE/.learnings/ERRORS.md"
  echo "### $(date '+%Y-%m-%d %H:%M') - 需介入 - $TASK_ID" >> "$WORKSPACE/.learnings/ERRORS.md"
  echo "- $1" >> "$WORKSPACE/.learnings/ERRORS.md"
}

# ─── 主逻辑 ───
log "处理: $ERROR_TYPE (卡死×$STUCK_COUNT)"
case "$ERROR_TYPE" in
  stuck)
    if [ "$STUCK_COUNT" -lt 1 ]; then try_strategy
    elif [ "$STUCK_COUNT" -lt 3 ]; then try_rollback || try_strategy
    else notify_user "连续卡死 $((STUCK_COUNT + 1)) 次"
    fi ;;
  max_iterations)
    local old; old=$(jq -r '.max_iterations' "$TASK_JSON" 2>/dev/null || echo 50)
    jq --argjson m "$((old + 25))" '.max_iterations = $m | .state = "in_progress"' "$TASK_JSON" > "/tmp/tc-$$.json" 2>/dev/null && mv "/tmp/tc-$$.json" "$TASK_JSON"
    log "迭代上限增加到 $((old + 25))" ;;
  tool_error)
    local reg="$WORKSPACE/.tool-registry.json"
    [ -f "$reg" ] && jq --arg t "$(echo "$ERROR_DETAIL" | grep -oP 'tool \K\S+' || echo unknown)" '(.tools[]? | select(.id == $t or .name == $t)) |= (.errorCount += 1)' "$reg" > "/tmp/r-$$.json" 2>/dev/null && mv "/tmp/r-$$.json" "$reg"
    local cur; cur=$(jq -r '[.subtasks[]? | select(.state == "in_progress")] | first | .id // "none"' "$TASK_JSON" 2>/dev/null)
    [ "$cur" != "none" ] && jq --arg id "$cur" '(.subtasks[] | select(.id == $id)) |= (.state = "pending")' "$TASK_JSON" > "/tmp/tc-$$.json" 2>/dev/null && mv "/tmp/tc-$$.json" "$TASK_JSON" ;;
  verify_failed)
    local cur; cur=$(jq -r '[.subtasks[]? | select(.state == "in_progress")] | first | .id // "none"' "$TASK_JSON" 2>/dev/null)
    if [ "$cur" != "none" ]; then
      local att; att=$(jq -r --arg id "$cur" '.subtasks[] | select(.id == $id) | .attempts' "$TASK_JSON" 2>/dev/null || echo 0)
      local max_a; max_a=$(jq -r --arg id "$cur" '.subtasks[] | select(.id == $id) | .max_attempts' "$TASK_JSON" 2>/dev/null || echo 3)
      if [ "$att" -ge "$max_a" ]; then
        jq --arg id "$cur" '(.subtasks[] | select(.id == $id)) |= (.state = "blocked")' "$TASK_JSON" > "/tmp/tc-$$.json" 2>/dev/null && mv "/tmp/tc-$$.json" "$TASK_JSON"
      else
        jq --arg id "$cur" '(.subtasks[] | select(.id == $id)) |= (.state = "pending")' "$TASK_JSON" > "/tmp/tc-$$.json" 2>/dev/null && mv "/tmp/tc-$$.json" "$TASK_JSON"
      fi
    fi ;;
  *) notify_user "未知错误: $ERROR_TYPE - $ERROR_DETAIL" ;;
esac
log "纠错完成"
