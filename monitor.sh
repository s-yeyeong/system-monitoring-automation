#!/bin/bash
# ============================================================
# monitor.sh - 시스템 상태 수집 및 로깅 자동화 스크립트
# 위치: $AGENT_HOME/bin/monitor.sh
# 소유: agent-dev:agent-core | 권한: 750 (rwxr-x---)
# 실행: agent-admin (crontab 매분 자동 실행)
# ============================================================

# --- 공통 환경 설정 ---
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
AGENT_LOG_DIR=/var/log/agent-app
LOG_FILE=$AGENT_LOG_DIR/monitor.log
MAX_LOG_SIZE=10485760   # 10MB (10 * 1024 * 1024)
MAX_LOG_FILES=10
NOW=$(date "+%Y-%m-%d %H:%M:%S")

# ============================================================
# [STEP 1] Health Check – 프로세스 & 포트 상태 확인
#   - 앱 프로세스(agent_app.py)가 실행 중인지 확인
#   - TCP 15034 포트가 LISTEN 상태인지 확인
#   - 비정상 시 즉시 exit 1로 종료 (크론 로그에 실패 기록)
# ============================================================
echo ""
echo "====== SYSTEM MONITOR RESULT ======"
echo ""
echo "[HEALTH CHECK]"

PID=$(pgrep -f agent_app.py)
if [ -z "$PID" ]; then
    echo "Checking process 'agent_app.py'... [FAIL] (Not Running)"
    echo "[$NOW] [CRITICAL] agent_app.py process NOT found. Aborting." >> $LOG_FILE
    exit 1
fi
echo "Checking process 'agent_app.py'... [OK] (PID: $PID)"

if ! ss -tuln | grep -q ":15034"; then
    echo "Checking port 15034... [FAIL] (Not Listening)"
    echo "[$NOW] [CRITICAL] Port 15034 NOT listening. Aborting." >> $LOG_FILE
    exit 1
fi
echo "Checking port 15034... [OK]"

# ============================================================
# [STEP 2] 상태 점검 – 방화벽(UFW) 활성 여부
#   - 비활성이면 [WARNING] 출력, 스크립트는 종료하지 않음
# ============================================================
WARN_MSG=""
if ! ufw status 2>/dev/null | grep -qw "active"; then
    WARN_MSG="$WARN_MSG [WARNING: UFW Inactive]"
fi

# ============================================================
# [STEP 3] 자원 수집 – CPU / MEM / DISK 사용률 측정
#   - top:  CPU idle을 기반으로 사용률 계산
#   - free: 전체 메모리 대비 사용 메모리 비율 계산
#   - df:   루트 파티션(/) 사용률 추출
# ============================================================
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')
MEM_USAGE=$(free | grep Mem | awk '{printf("%.0f", $3/$2 * 100)}')
DISK_USAGE=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')

echo ""
echo "[RESOURCE MONITORING]"
echo "CPU Usage : ${CPU_USAGE}%"
echo "MEM Usage : ${MEM_USAGE}%"
echo "DISK Used  : ${DISK_USAGE}%"

# ============================================================
# [STEP 4] 임계값 경고 – 기준치 초과 시 WARNING 출력
#   - CPU  > 20%  → [WARNING]
#   - MEM  > 10%  → [WARNING]
#   - DISK > 80%  → [WARNING]
#   ※ 경고만 출력하며, 스크립트를 종료하지는 않음
# ============================================================
echo ""
if [ $(echo "$CPU_USAGE > 20" | bc -l) -eq 1 ]; then
    WARN_MSG="$WARN_MSG [WARNING: CPU High]"
    echo "[WARNING] CPU threshold exceeded (${CPU_USAGE}% > 20%)"
fi
if [ "$MEM_USAGE" -gt 10 ]; then
    WARN_MSG="$WARN_MSG [WARNING: MEM High]"
    echo "[WARNING] MEM threshold exceeded (${MEM_USAGE}% > 10%)"
fi
if [ "$DISK_USAGE" -gt 80 ]; then
    WARN_MSG="$WARN_MSG [WARNING: DISK High]"
    echo "[WARNING] DISK threshold exceeded (${DISK_USAGE}% > 80%)"
fi

# ============================================================
# [STEP 5] 로그 기록 – 수집 결과를 로그 파일에 추가
#   포맷: [YYYY-MM-DD HH:MM:SS] PID:... CPU:..% MEM:..% DISK_USED:..%
# ============================================================
echo "[$NOW] PID:$PID CPU:${CPU_USAGE}% MEM:${MEM_USAGE}% DISK_USED:${DISK_USAGE}% $WARN_MSG" >> $LOG_FILE
echo ""
echo "[INFO] Log appended: $LOG_FILE"

# ============================================================
# [STEP 6] 로그 파일 용량 관리 (자체 로테이션 로직)
#   - monitor.log가 10MB 초과 시 .1 ~ .10으로 순환 보관
#   - 가장 오래된 파일(.10)은 자동 삭제
#   ※ logrotate와 병행 사용도 가능하며, 여기서는 스크립트
#     자체 로직으로도 안전장치를 구현
# ============================================================
if [ -f "$LOG_FILE" ]; then
    FILE_SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$FILE_SIZE" -gt "$MAX_LOG_SIZE" ]; then
        # 가장 오래된 로그 삭제
        [ -f "${LOG_FILE}.${MAX_LOG_FILES}" ] && rm -f "${LOG_FILE}.${MAX_LOG_FILES}"
        # 기존 로그 번호를 하나씩 밀어냄 (9→10, 8→9, ...)
        for i in $(seq $((MAX_LOG_FILES - 1)) -1 1); do
            [ -f "${LOG_FILE}.${i}" ] && mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
        done
        # 현재 로그를 .1로 이동하고 새 로그 파일 생성
        mv "$LOG_FILE" "${LOG_FILE}.1"
        touch "$LOG_FILE"
        echo "[$NOW] [INFO] Log rotated: ${LOG_FILE}.1" >> $LOG_FILE
    fi
fi
