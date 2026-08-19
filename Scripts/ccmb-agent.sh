#!/bin/bash
# CCMB 자동화 에이전트.
#
# 이 저장소 안의 .ccmb-agent/inbox 에 들어오는 쉘 스크립트를 하나씩 실행하고
# 결과를 .ccmb-agent/outbox 에 남긴다. 클로드가 맥에서 직접 빌드·테스트·설치를
# 수행하기 위한 통로이며, 이 폴더 밖의 요청은 받지 않는다.
#
# 끄려면 "CCMB 자동화 끄기.command" 를 더블클릭한다.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
AGENT_DIR="$ROOT_DIR/.ccmb-agent"
IN_DIR="$AGENT_DIR/inbox"
OUT_DIR="$AGENT_DIR/outbox"
DONE_DIR="$AGENT_DIR/done"
MAX_SECONDS=2400

mkdir -p "$IN_DIR" "$OUT_DIR" "$DONE_DIR"

# Xcode 명령줄 도구 경로를 launchd 환경에서도 확실히 잡는다.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"

cleanup() {
  rm -f "$AGENT_DIR/agent.pid"
  printf 'stopped %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "$AGENT_DIR/status"
}
trap cleanup EXIT INT TERM

printf '%s\n' "$$" > "$AGENT_DIR/agent.pid"
printf 'CCMB 자동화 에이전트 시작: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf '감시 폴더: %s\n' "$IN_DIR"

while true; do
  printf 'running %s pid=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" > "$AGENT_DIR/status"

  for req in "$IN_DIR"/*.sh; do
    [ -e "$req" ] || continue
    name="$(basename "$req" .sh)"

    # 실행 전에 inbox 밖으로 옮겨서 같은 작업이 두 번 실행되지 않게 한다.
    mv "$req" "$DONE_DIR/$name.sh" 2>/dev/null || continue

    printf '\n[%s] 실행 시작: %s\n' "$(date '+%H:%M:%S')" "$name"
    rm -f "$OUT_DIR/$name.status"

    # 안전장치: 사용자 화면에 모달 권한 창을 띄울 수 있는 명령은 실행하지
    # 않는다. 그런 창은 키보드 입력을 전부 삼켜서 맥을 먹통처럼 보이게 한다.
    if grep -qE 'osascript|find-generic-password|security[[:space:]]+(add|unlock|import)' "$DONE_DIR/$name.sh"; then
      printf '거부: 이 작업은 권한 대화상자를 띄울 수 있는 명령을 포함합니다.\n' > "$OUT_DIR/$name.log"
      grep -nE 'osascript|find-generic-password|security[[:space:]]+(add|unlock|import)' "$DONE_DIR/$name.sh" >> "$OUT_DIR/$name.log"
      printf '%s\n' "77" > "$OUT_DIR/$name.status"
      printf '[%s] 거부됨: %s\n' "$(date '+%H:%M:%S')" "$name"
      continue
    fi

    # 표준 입력을 끊어 어떤 명령도 사용자 입력을 기다리지 못하게 한다.
    ( cd "$ROOT_DIR" && /bin/bash "$DONE_DIR/$name.sh" ) < /dev/null > "$OUT_DIR/$name.log" 2>&1 &
    job=$!

    waited=0
    while kill -0 "$job" 2>/dev/null; do
      sleep 2
      waited=$((waited + 2))
      if [ "$waited" -ge "$MAX_SECONDS" ]; then
        printf '\n에이전트: %s초를 넘겨 강제 종료했습니다.\n' "$MAX_SECONDS" >> "$OUT_DIR/$name.log"
        kill -9 "$job" 2>/dev/null
        break
      fi
    done

    wait "$job"
    code=$?
    printf '%s\n' "$code" > "$OUT_DIR/$name.status"
    printf '[%s] 완료: %s (종료코드 %s)\n' "$(date '+%H:%M:%S')" "$name" "$code"
  done

  sleep 2
done
