#!/bin/bash
# watchdog.sh — 5场景卡死检测 v4.1
# 来源: OpenHands StuckDetector + Cline loop-detection
set -euo pipefail

TRACE="${1:?用法: watchdog.sh <trace.jsonl> [max_iter]}"
MAX="${2:-50}"

[ ! -f "$TRACE" ] && { echo "✅ 首次运行"; exit 0; }

LINES=$(wc -l < "$TRACE" | tr -d ' ')

# 硬上限 (OpenAI max_turns)
[ "$LINES" -ge "$MAX" ] && { echo "🚫 [MAX_ITER] $LINES/$MAX"; exit 1; }
[ "$LINES" -lt 3 ] && { echo "✅ 未检测到卡死 ($LINES/$MAX)"; exit 0; }

# S1: 同一动作+结果×4
if [ "$LINES" -ge 4 ]; then
  SIGS=$(tail -4 "$TRACE" | jq -r '(.action // "?") + "|" + (.result // "none")[:80]' 2>/dev/null)
  if [ -n "$SIGS" ] && [ "$(echo "$SIGS" | sort -u | wc -l | tr -d ' ')" -eq 1 ]; then
    echo "🚫 [S1] 同一动作+结果×4"; exit 1
  fi
fi

# S2: 同一动作+错误×3
if [ "$LINES" -ge 3 ]; then
  FAILS=$(tail -3 "$TRACE" | jq -s 'all(.[]; .success == false)' 2>/dev/null || echo false)
  ACTS=$(tail -3 "$TRACE" | jq -r '.action // "?"' 2>/dev/null)
  if [ "$FAILS" = "true" ] && [ -n "$ACTS" ] && [ "$(echo "$ACTS" | sort -u | wc -l | tr -d ' ')" -eq 1 ]; then
    echo "🚫 [S2] 同一动作+错误×3"; exit 1
  fi
fi

# S3: Agent独白×3
if [ "$LINES" -ge 3 ]; then
  MSGS=$(tail -3 "$TRACE" | jq -r '.agent_message // ""' 2>/dev/null | grep -v '^$' || true)
  if [ -n "$MSGS" ]; then
    MC=$(echo "$MSGS" | wc -l | tr -d ' ')
    MU=$(echo "$MSGS" | sort -u | wc -l | tr -d ' ')
    [ "$MC" -ge 3 ] && [ "$MU" -eq 1 ] && { echo "🚫 [S3] 独白×3"; exit 1; }
  fi
fi

# S4: 交替循环 A→B→A→B→A→B
if [ "$LINES" -ge 6 ]; then
  A=$(tail -6 "$TRACE" | jq -r '.action // "?"' 2>/dev/null)
  if [ -n "$A" ]; then
    L1=$(echo "$A" | sed -n '1p'); L2=$(echo "$A" | sed -n '2p')
    L3=$(echo "$A" | sed -n '3p'); L4=$(echo "$A" | sed -n '4p')
    L5=$(echo "$A" | sed -n '5p'); L6=$(echo "$A" | sed -n '6p')
    [ "$L1" = "$L3" ] && [ "$L3" = "$L5" ] && [ "$L2" = "$L4" ] && [ "$L4" = "$L6" ] && [ "$L1" != "$L2" ] && { echo "🚫 [S4] 交替 $L1↔$L2"; exit 1; }
  fi
fi

# S5: 上下文错误×10
if [ "$LINES" -ge 10 ]; then
  CE=$(tail -10 "$TRACE" | jq -s '[.[] | select(.error != null and (.error | test("context|token|window"; "i")))] | length' 2>/dev/null || echo 0)
  [ "$CE" -ge 10 ] && { echo "🚫 [S5] 上下文错误×$CE"; exit 1; }
fi

echo "✅ 未检测到卡死 ($LINES/$MAX)"
exit 0

# 统计信息（可选输出）
# 使用: WATCHDOG_STATS=1 bash watchdog.sh trace.jsonl 50
if [ "${WATCHDOG_STATS:-0}" = "1" ] && [ "$LINES" -gt 0 ]; then
  echo "--- 统计 ---"
  echo "总操作: $LINES"
  echo "成功: $(jq -s '[.[] | select(.success == true)] | length' "$TRACE" 2>/dev/null || echo 0)"
  echo "失败: $(jq -s '[.[] | select(.success == false)] | length' "$TRACE" 2>/dev/null || echo 0)"
  echo "操作类型: $(jq -r '.action' "$TRACE" 2>/dev/null | sort | uniq -c | sort -rn | head -5)"
fi
