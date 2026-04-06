# HEARTBEAT.md

## 持久任务检查 (Persistent Task Check)
1. 运行 `find ~/.openclaw/workspace/tasks -name "task-list.json" -exec grep -l '"status":"in_progress"\|"status":"paused"' {} \;` 查找活跃任务
2. 如果有活跃任务 → 读取该任务的 task-list.json 和 progress.md，继续执行下一个子任务
3. 如果任务所有子任务都 completed → 生成汇报，通知用户
4. 如果没有活跃任务 → 跳过

## 自主工作检查 (Autonomous Work Check)
仅在没有活跃任务时执行（每 4 次心跳检查 1 次）：
1. 检查 `.learnings/ERRORS.md` 是否有未处理的错误
2. 检查 `.tool-registry.json` 中 status="unknown" 的工具
3. 检查 MEMORY.md 是否超过 7 天未整理
4. 以上都没有 → HEARTBEAT_OK
