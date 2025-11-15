#!/bin/bash
# wait-for-sync.sh
# 
# 等待 sync 守护进程完成初始同步
# 
# 此脚本由其他服务在启动前调用，确保所有数据（Git + LFS）已完全同步

SYNC_COMPLETE="/home/user/.astrbot-backup/.sync-complete"
SYNC_PROGRESS="/home/user/.astrbot-backup/.sync-progress.json"
MAX_WAIT=${SYNC_WAIT_TIMEOUT:-1800}  # 默认 30 分钟超时
ELAPSED=0
CHECK_INTERVAL=5

echo "[wait-for-sync] Waiting for sync to complete..."
echo "[wait-for-sync] Timeout: ${MAX_WAIT} seconds"

while [ $ELAPSED -lt $MAX_WAIT ]; do
    # 检查同步完成标记文件
    if [ -f "$SYNC_COMPLETE" ]; then
        # 验证文件是否是最近创建的（避免使用旧标记）
        FILE_AGE=$(($(date +%s) - $(stat -c %Y "$SYNC_COMPLETE" 2>/dev/null || echo 0)))
        
        if [ $FILE_AGE -lt 600 ]; then  # 10 分钟内创建
            echo "[wait-for-sync] ✓ Sync completed! Starting service..."
            exit 0
        else
            echo "[wait-for-sync] ⚠ Sync complete marker is too old (${FILE_AGE}s), waiting for fresh sync..."
        fi
    fi
    
    # 显示当前进度（如果有）
    if [ -f "$SYNC_PROGRESS" ]; then
        # 尝试解析 JSON 进度
        STAGE=$(cat "$SYNC_PROGRESS" 2>/dev/null | grep -o '"stage":"[^"]*"' | cut -d'"' -f4)
        PROGRESS=$(cat "$SYNC_PROGRESS" 2>/dev/null | grep -o '"progress":[0-9]*' | cut -d: -f2)
        CURRENT=$(cat "$SYNC_PROGRESS" 2>/dev/null | grep -o '"current":[0-9]*' | cut -d: -f2)
        TOTAL=$(cat "$SYNC_PROGRESS" 2>/dev/null | grep -o '"total":[0-9]*' | cut -d: -f2)
        
        if [ -n "$PROGRESS" ]; then
            if [ -n "$CURRENT" ] && [ -n "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
                echo "[wait-for-sync] Progress: ${PROGRESS}% (Stage: ${STAGE}, ${CURRENT}/${TOTAL} files)"
            else
                echo "[wait-for-sync] Progress: ${PROGRESS}% (Stage: ${STAGE})"
            fi
        else
            echo "[wait-for-sync] Waiting... (${ELAPSED}s elapsed)"
        fi
    else
        echo "[wait-for-sync] Waiting for sync to start... (${ELAPSED}s elapsed)"
    fi
    
    sleep $CHECK_INTERVAL
    ELAPSED=$((ELAPSED + CHECK_INTERVAL))
done

# 超时处理
echo "[wait-for-sync] ⚠ Timeout after ${MAX_WAIT} seconds"
echo "[wait-for-sync] Starting service anyway to avoid permanent block..."
echo "[wait-for-sync] Note: Some data may not be fully synced!"

# 即使超时也返回 0，允许服务启动（避免永久阻塞）
exit 0