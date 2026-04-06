#!/bin/bash
# evolve.sh v4.1 — 自我进化引擎
set -uo pipefail
# 注意: 不用 -e 因为 find/jq 可能返回非0

WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}"
LEARNINGS_DIR="$WORKSPACE/.learnings"
REGISTRY="$WORKSPACE/.tool-registry.json"
TODAY=$(date '+%Y-%m-%d')
log() { echo "[$(date '+%H:%M')] 🔬 $1"; }

mkdir -p "$LEARNINGS_DIR" "$WORKSPACE/memory"

log "═══ 进化检查 v4.1 ═══"

# 1. 错误模式分析
EF="$LEARNINGS_DIR/ERRORS.md"
if [ -f "$EF" ]; then
  TOTAL=$(grep -c '^### ' "$EF" 2>/dev/null || echo 0)
  if [ "$TOTAL" -ge 3 ]; then
    log "分析 $TOTAL 条错误..."
    grep '^### ' "$EF" | tail -10 | sed 's/^### /  /'
  else
    log "错误数 $TOTAL 不足以分析"
  fi
fi

# 2. 工具健康检查
if [ -f "$REGISTRY" ]; then
  TC=$(jq '.tools | length' "$REGISTRY" 2>/dev/null || echo 0)
  if [ "$TC" -gt 0 ]; then
    log "检查 $TC 个工具..."
    ACTIVE=$(jq -r '.tools[] | select(.status == "active") | .id + "|" + (.healthCheck // "") + "|" + .name' "$REGISTRY" 2>/dev/null || true)
    if [ -n "$ACTIVE" ]; then
      echo "$ACTIVE" | while IFS='|' read -r id check name; do
        [ -z "$check" ] && continue
        if timeout 5 bash -c "$check" >/dev/null 2>&1; then
          log "  ✅ $name"
        else
          log "  ❌ $name"
        fi
      done
    else
      log "  无活跃工具"
    fi
  fi
fi

# 3. 进度压缩 (>200行)
PMDS=$(find "$WORKSPACE/tasks" -maxdepth 2 -name "progress.md" 2>/dev/null || true)
if [ -n "$PMDS" ]; then
  echo "$PMDS" | while read -r pmd; do
    LINES=$(wc -l < "$pmd" | tr -d ' ')
    if [ "$LINES" -gt 200 ]; then
      log "压缩 $(basename "$(dirname "$pmd")"): $LINES→~80 行"
      { head -25 "$pmd"; echo ""; echo "## 压缩 $TODAY"; tail -50 "$pmd"; } > "$pmd.tmp" && mv "$pmd.tmp" "$pmd"
    fi
  done
fi

# 4. Trace清理 (>100行截断)
TRACES=$(find "$WORKSPACE/tasks" -maxdepth 2 -name "stuck-trace.jsonl" 2>/dev/null || true)
if [ -n "$TRACES" ]; then
  echo "$TRACES" | while read -r tf; do
    LINES=$(wc -l < "$tf" | tr -d ' ')
    if [ "$LINES" -gt 100 ]; then
      tail -50 "$tf" > "$tf.tmp" && mv "$tf.tmp" "$tf"
      log "  ✂️ trace $LINES→50"
    fi
  done
fi

log "═══ 进化完成 ═══"
