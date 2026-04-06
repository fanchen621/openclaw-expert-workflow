# HEARTBEAT.md

## 活跃任务检查
1. 运行 `bash ~/.openclaw/workspace/agent-expert-workflow/scripts/master-orchestrator.sh 2>&1`
2. 如果输出包含 `HEARTBEAT_OK` → HEARTBEAT_OK
3. 如果输出包含任务执行结果/错误/完成 → 转发给用户
4. 如果脚本出错 → 记录到 .learnings/ERRORS.md 并 HEARTBEAT_OK
