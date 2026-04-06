#!/bin/bash
# task-init.sh — 智能任务初始化 v4.1
# 来源: Claude Code XN5复杂度 + Anthropic 双Agent
set -euo pipefail

DESC="${1:?用法: task-init.sh '描述' [--time-start HH:MM] [--time-end HH:MM] [--max-iter N]}"
shift

TIME_S="" TIME_E="" MAX_ITER=50
while [ $# -gt 0 ]; do
  case "$1" in
    --time-start) TIME_S="$2"; shift 2 ;;
    --time-end) TIME_E="$2"; shift 2 ;;
    --max-iter) MAX_ITER="$2"; shift 2 ;;
    *) shift ;;
  esac
done

WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}"
TASKS_DIR="$WORKSPACE/tasks"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 复杂度评估 (XN5风格)
assess() {
  local d="$1" s=0
  if echo "$d" | grep -qiE "深入|全面|重构|架构|系统|整个|所有"; then s=$((s + 10000)); fi
  if echo "$d" | grep -qiE "创建|实现|写|开发|构建|设计|修改|更新|添加"; then s=$((s + 5000)); fi
  if echo "$d" | grep -qiE "查看|读取|检查|搜索|查找|列出|显示"; then s=$((s + 1000)); fi
  local cc; cc=$(echo "$d" | wc -c | tr -d ' ')
  if [ "$cc" -gt 100 ]; then s=$((s + 3000)); elif [ "$cc" -gt 50 ]; then s=$((s + 1500)); elif [ "$cc" -gt 30 ]; then s=$((s + 500)); fi
  local cm; cm=$(echo "$d" | tr -cd ",，。.:;" | wc -c | tr -d " ")
  if [ "$cm" -ge 3 ]; then s=$((s + 2000)); elif [ "$cm" -ge 1 ]; then s=$((s + 500)); fi
  if [ "$s" -ge 10000 ]; then echo HIGHEST
  elif [ "$s" -ge 5000 ]; then echo MIDDLE
  elif [ "$s" -ge 1000 ]; then echo BASIC
  else echo NONE
  fi
}

CX=$(assess "$DESC")
echo "📊 复杂度: $CX"
[ "$CX" = "NONE" ] && { echo "太简单，不需要任务文件"; exit 0; }

case "$CX" in HIGHEST) [ "$MAX_ITER" -eq 50 ] && MAX_ITER=100 ;; BASIC) [ "$MAX_ITER" -eq 50 ] && MAX_ITER=20 ;; esac

TASK_ID=$(date +%Y%m%d-%H%M%S)
SLUG=$(echo "$DESC" | tr ' ' '-' | tr -cd 'a-zA-Z0-9_-' | cut -c1-30)
SLUG="${SLUG:-task}"
SLUG=$(echo "$SLUG" | sed 's/-$//')
TASK_DIR="$TASKS_DIR/${TASK_ID}-${SLUG}"
mkdir -p "$TASK_DIR"

NOW=$(date -Iseconds)
if [ -n "$TIME_S" ] && [ -n "$TIME_E" ]; then
  TD=$(date '+%Y-%m-%d')
  WS="${TD}T${TIME_S}:00+08:00"; WE="${TD}T${TIME_E}:00+08:00"
  SE=$(date -d "$WS" +%s 2>/dev/null || echo 0); EE=$(date -d "$WE" +%s 2>/dev/null || echo 0)
  BUDGET=$(( (EE - SE) / 60 ))
else
  WS="$NOW"; WE=""; BUDGET=0
fi

cat > "$TASK_DIR/task.json" << JSON
{"id":"$TASK_ID","title":"$(echo "$DESC" | tr "\n" " ")","complexity":"$CX","state":"planning","created_at":"$NOW",
"time_window":{"start":"$WS","end":"$WE","budget_minutes":$BUDGET},
"max_iterations":$MAX_ITER,"current_iteration":0,"subtasks":[],"checkpoints":[],"stuck_count":0,"errors":[]}
JSON

cat > "$TASK_DIR/progress.md" << MD
# $DESC
- ID: $TASK_ID | 复杂度: $CX | 最大迭代: $MAX_ITER
$([ -n "$WE" ] && echo "- 时间: $TIME_S-$TIME_E ($BUDGET 分钟)")
## 状态: 等待拆解
## 执行日志
## 关键发现
MD

touch "$TASK_DIR/stuck-trace.jsonl"

cd "$WORKSPACE" && git rev-parse --git-dir >/dev/null 2>&1 && { git add -A; git commit -m "checkpoint: $TASK_ID" --quiet 2>/dev/null || true; }

echo "📁 $TASK_DIR"
echo "📋 复杂度=$CX 最大迭代=$MAX_ITER"
echo "✅ 初始化完成"
