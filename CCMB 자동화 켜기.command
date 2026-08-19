#!/bin/bash
# 딱 한 번만 더블클릭하면 됩니다.
# CCMB 자동화 에이전트를 로그인 항목으로 등록하고 바로 시작합니다.
# 이후에는 재부팅해도 자동으로 켜집니다.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
AGENT_DIR="$ROOT_DIR/.ccmb-agent"
LABEL="com.armsone.ccmb.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$AGENT_DIR/inbox" "$AGENT_DIR/outbox" "$AGENT_DIR/done" "$HOME/Library/LaunchAgents"

printf 'CCMB 자동화를 설치합니다.\n'
printf '대상 폴더: %s\n\n' "$ROOT_DIR"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$ROOT_DIR/Scripts/ccmb-agent.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$AGENT_DIR/agent.log</string>
  <key>StandardErrorPath</key>
  <string>$AGENT_DIR/agent.log</string>
  <key>WorkingDirectory</key>
  <string>$ROOT_DIR</string>
</dict>
</plist>
PLISTEOF

plutil -lint "$PLIST" || { printf '설정 파일 검증 실패\n'; read -r -n 1 -s; exit 1; }

launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1
if ! launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null; then
  launchctl unload "$PLIST" >/dev/null 2>&1
  launchctl load -w "$PLIST" || { printf '등록에 실패했습니다.\n'; read -r -n 1 -s; exit 1; }
fi
launchctl kickstart -k "gui/$UID/$LABEL" >/dev/null 2>&1

sleep 3
if [ -f "$AGENT_DIR/status" ] && grep -q '^running' "$AGENT_DIR/status"; then
  printf '완료되었습니다. 자동화가 켜졌습니다.\n'
  cat "$AGENT_DIR/status"
  printf '\n이제 클로드가 이 맥에서 직접 빌드하고 설치합니다.\n'
  printf '끄고 싶으면 "CCMB 자동화 끄기.command" 를 더블클릭하세요.\n'
else
  printf '시작 확인에 실패했습니다. 아래 로그를 클로드에게 알려주세요.\n'
  tail -n 30 "$AGENT_DIR/agent.log" 2>/dev/null
fi

printf '\n아무 키나 누르면 창이 닫힙니다...'
read -r -n 1 -s
printf '\n'
