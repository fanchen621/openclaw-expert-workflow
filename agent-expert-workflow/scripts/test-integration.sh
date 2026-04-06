#!/bin/bash
# test-integration.sh — 端到端集成测试 v4.1
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
PASS=0 FAIL=0

test_case() {
  local name="$1" expect="$2" actual="$3"
  if [ "$expect" = "$actual" ]; then
    echo "  ✅ $name"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $name: 期望='$expect' 实际='$actual'"
    FAIL=$((FAIL + 1))
  fi
}

echo "═══ 端到端集成测试 ═══"
echo ""

# ─── 1. trace-logger ───
echo "1. trace-logger"
T=/tmp/itest-$$.jsonl; > "$T"
bash "$SCRIPTS/trace-logger.sh" "$T" "read" true "content" "" "" >/dev/null
LINES=$(wc -l < "$T" | tr -d ' ')
test_case "写入1行" "1" "$LINES"
HAS_ACTION=$(jq -r '.action' "$T")
test_case "action正确" "read" "$HAS_ACTION"

# ─── 2. watchdog ───
echo "2. watchdog"
# 场景1: 同一动作+结果×4
T2=/tmp/itest-wd-$$.jsonl; > "$T2"
for i in 1 2 3 4; do bash "$SCRIPTS/trace-logger.sh" "$T2" "x" true "y" >/dev/null; done
WD=$(bash "$SCRIPTS/watchdog.sh" "$T2" 50 2>&1 || true)
test_case "S1检测循环" "true" "$(echo "$WD" | grep -q S1 && echo true || echo false)"
# 不触发: 不同结果
T3=/tmp/itest-wd2-$$.jsonl; > "$T3"
for i in a b c d; do bash "$SCRIPTS/trace-logger.sh" "$T3" "r" true "$i" >/dev/null; done
WD2=$(bash "$SCRIPTS/watchdog.sh" "$T3" 50 2>&1)
test_case "不同结果不误判" "true" "$(echo "$WD2" | grep -q '未检测到' && echo true || echo false)"
# 硬上限
T4=/tmp/itest-wd3-$$.jsonl; > "$T4"
for i in $(seq 5); do bash "$SCRIPTS/trace-logger.sh" "$T4" "x" true "y" >/dev/null; done
WD3=$(bash "$SCRIPTS/watchdog.sh" "$T4" 4 2>&1 || true)
test_case "MAX_ITER检测" "true" "$(echo "$WD3" | grep -q MAX_ITER && echo true || echo false)"

# ─── 3. task-init ───
echo "3. task-init"
OUT=$(bash "$SCRIPTS/task-init.sh" "深入分析并重构整个项目的认证模块" --max-iter 30 2>&1)
test_case "HIGHEST评估" "true" "$(echo "$OUT" | grep -q HIGHEST && echo true || echo false)"
TASK_D=$(echo "$OUT" | grep "📁" | awk '{print $2}')
test_case "创建目录" "true" "$(test -f "$TASK_D/task.json" && echo true || echo false)"
test_case "task.json有效" "true" "$(jq -r '.complexity' "$TASK_D/task.json" 2>/dev/null | grep -q HIGHEST && echo true || echo false)"
rm -rf "$TASK_D"

OUT2=$(bash "$SCRIPTS/task-init.sh" "查看登录页面" --max-iter 10 2>&1)
test_case "BASIC评估" "true" "$(echo "$OUT2" | grep -q BASIC && echo true || echo false)"
TASK_D2=$(echo "$OUT2" | grep "📁" | awk '{print $2}')
rm -rf "$TASK_D2"

OUT3=$(bash "$SCRIPTS/task-init.sh" "hello" 2>&1)
test_case "NONE评估" "true" "$(echo "$OUT3" | grep -q NONE && echo true || echo false)"

# ─── 4. task-loop ───
echo "4. task-loop"
TD=/tmp/itest-tl-$$; mkdir -p "$TD"
echo '{"id":"t","title":"test","state":"planning","subtasks":[],"max_iterations":10,"current_iteration":0}' > "$TD/task.json"
LO=$(bash "$SCRIPTS/task-loop.sh" "$TD" 2>&1)
test_case "空子任务保持planning" "true" "$(echo "$LO" | grep -q '保持 planning' && echo true || echo false)"
S=$(jq -r '.state' "$TD/task.json")
test_case "state=planning" "planning" "$S"
rm -rf "$TD"

# 带子任务
TD2=/tmp/itest-tl2-$$; mkdir -p "$TD2"
cat > "$TD2/task.json" << 'J'
{"id":"t","title":"test","state":"in_progress","subtasks":[{"id":"ST-1","title":"x","priority":1,"state":"pending","verify":{"type":"command","criteria":"true","expected":"ok"},"attempts":0,"max_attempts":3}],"max_iterations":10,"current_iteration":0}
J
touch "$TD2/stuck-trace.jsonl"
LO2=$(bash "$SCRIPTS/task-loop.sh" "$TD2" 2>&1)
test_case "执行子任务ST-1" "true" "$(echo "$LO2" | grep -q 'ST-1' && echo true || echo false)"
I=$(jq -r '.current_iteration' "$TD2/task.json")
test_case "迭代+1" "1" "$I"
rm -rf "$TD2"

# ─── 5. master-orchestrator ───
echo "5. master-orchestrator"
MO=$(bash "$SCRIPTS/master-orchestrator.sh" 2>&1)
test_case "输出HEARTBEAT_OK" "true" "$(echo "$MO" | grep -q HEARTBEAT_OK && echo true || echo false)"

# ─── 6. evolve ───
echo "6. evolve"
EO=$(bash "$SCRIPTS/evolve.sh" 2>&1)
test_case "evolve执行成功" "true" "$(echo "$EO" | grep -q '进化完成' && echo true || echo false)"

echo ""
echo "═══ 结果: ✅ $PASS 通过, ❌ $FAIL 失败 ═══"
[ "$FAIL" -eq 0 ] && echo "🎉 全部通过！" || echo "⚠️ 有失败项需要修复"
exit $FAIL
