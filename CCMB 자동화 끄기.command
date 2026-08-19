#!/bin/bash
# CCMB 앱과 자동화 에이전트를 즉시 모두 중지합니다.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
LABEL="com.armsone.ccmb.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# 1) CCMB를 먼저 죽인다. 메뉴가 열린 채 앱이 멈추면 키보드 입력이 잡히므로
#    이걸 가장 먼저, 가장 강하게 처리한다.
pkill -9 -x CodexCreditMenuBar 2>/dev/null && printf 'CCMB 강제 종료함\n' || printf 'CCMB 실행 중 아님\n'

# 2) 자동화 에이전트 제거
launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1
launchctl unload "$PLIST" >/dev/null 2>&1
rm -f "$PLIST"
pkill -f "ccmb-agent.sh" >/dev/null 2>&1
printf '자동화 에이전트 제거함\n'

printf '\n전부 중지했습니다.\n'
printf '\n아무 키나 누르면 창이 닫힙니다...'
read -r -n 1 -s
printf '\n'
