#!/bin/bash
set -euo pipefail
TRACE="${1:?用法: trace-logger.sh <file> <action> <success> [result] [error] [msg]}"
ACTION="${2:?缺少 action}"
SUCCESS="${3:?缺少 success}"
RESULT="${4:-}" ERROR="${5:-}" MSG="${6:-}"
HASH=$(echo -n "$RESULT" | md5sum | cut -d' ' -f1)
jq -nc --arg ts "$(date -Iseconds)" --arg a "$ACTION" --argjson s "$SUCCESS" \
  --arg r "$RESULT" --arg h "$HASH" --arg e "$ERROR" --arg m "$MSG" \
  '{timestamp:$ts,action:$a,success:$s,result:$r,result_hash:$h,error:$e,agent_message:$m}' >> "$TRACE" 2>/dev/null
