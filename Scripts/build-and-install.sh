#!/bin/bash
# 테스트 → 릴리스 빌드 → 서명 → /Applications 설치 → 재실행.
# 화면 대기 없이 끝까지 진행하고 종료 코드로 결과를 알린다.

set -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT_DIR" || exit 1
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:$PATH"

EXE="CodexCreditMenuBar"
step() { printf '\n==== %s ====\n' "$1"; }
fail() { printf '\n실패: %s\nCCMB_RESULT=FAIL:%s\n' "$1" "$2"; exit 1; }

printf 'CCMB 빌드 시작: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
sw_vers 2>&1
swift --version 2>&1 || fail "Swift 명령줄 도구를 찾을 수 없습니다." "no-swift"

step "0/6 서명 인증서 확인"
# 목록만 읽는다. 비밀번호를 묻지 않는다.
security find-identity -v -p codesigning 2>&1 || echo "(인증서 조회 실패)"
echo "--- 현재 설치된 CCMB 서명"
codesign -dvv /Applications/CCMB.app 2>&1 | grep -E "Authority|TeamIdentifier|Signature=" || echo "(설치본 없음)"

step "1/6 테스트"
./Scripts/swiftpm.sh test || fail "테스트가 통과하지 못했습니다." "test"

step "2/6 릴리스 빌드"
# 회귀 방지: 추적 영역을 updateTrackingAreas 안에서 다시 만들면 AppKit이 그
# 갱신을 또 예약해서 메인 스레드가 폭주한다. 메뉴가 열려 있으면 맥 전체
# 키보드가 멎는다. 한 번 당해봤으므로 소스 단계에서 막는다.
if grep -n "func updateTrackingAreas" Sources/CodexCreditMenuBar/*.swift >/dev/null 2>&1; then
  fail "updateTrackingAreas() 재정의가 있습니다. 추적 영역 폭주 위험이라 빌드를 막습니다." "tracking-rebuild"
fi
if [ "$(grep -c 'addTrackingArea' Sources/CodexCreditMenuBar/*.swift | awk -F: '{s+=$2} END {print s+0}')" -gt 2 ]; then
  fail "addTrackingArea 호출이 너무 많습니다(슬롯별 추적 영역 의심)." "tracking-many"
fi

./Scripts/swiftpm.sh build -c release || fail "컴파일 오류가 있습니다." "build"

BIN_DIR="$(./Scripts/swiftpm.sh build -c release --show-bin-path 2>/dev/null | tail -n 1)"
BIN="$BIN_DIR/$EXE"
[ -f "$BIN" ] || fail "빌드된 실행 파일을 찾을 수 없습니다: $BIN" "binary-missing"
printf '실행 파일: %s\n' "$BIN"

step "3/6 앱 번들 준비"
# Sparkle.framework를 실제로 품고 있는 번들만 기준으로 삼는다. 프레임워크가
# 빠진 번들을 복사하면 실행 즉시 dyld 오류로 죽는다.
TEMPLATE=""
for candidate in \
  "/Applications/CCMB.app" \
  "$ROOT_DIR/Products/Release/CCMB.app" \
  "$ROOT_DIR/Products/Release/CCMB-local.app"
do
  if [ -d "$candidate/Contents/Frameworks/Sparkle.framework" ]; then
    TEMPLATE="$candidate"; break
  fi
done
[ -n "$TEMPLATE" ] || fail "Sparkle.framework가 들어 있는 기준 CCMB.app을 찾지 못했습니다. Scripts/package-macos.sh 를 한 번 돌려야 합니다." "no-template"
printf '기준 번들: %s\n' "$TEMPLATE"

STAGE="$ROOT_DIR/Products/Release/CCMB-local.app"
if [ "$TEMPLATE" != "$STAGE" ]; then
  rm -rf "$STAGE"
  ditto "$TEMPLATE" "$STAGE" || fail "번들 복사에 실패했습니다." "ditto"
fi

DEST_BIN="$STAGE/Contents/MacOS/$EXE"
cp "$BIN" "$DEST_BIN" || fail "실행 파일 교체 실패" "copy-bin"
chmod 755 "$DEST_BIN"

# SwiftPM이 뱉는 실행 파일에는 번들 안 Frameworks를 찾는 경로가 없다.
# package-macos.sh 와 똑같이 넣어주지 않으면 Sparkle을 못 찾고 즉시 죽는다.
if ! otool -l "$DEST_BIN" | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$DEST_BIN" \
    || fail "프레임워크 검색 경로(rpath) 추가 실패" "rpath"
fi
printf '%s\n' '--- LC_RPATH 확인 ---'
otool -l "$DEST_BIN" | grep -A2 LC_RPATH | grep 'path ' || fail "rpath가 없습니다." "rpath-verify"
[ -d "$STAGE/Contents/Frameworks/Sparkle.framework" ] || fail "번들에 Sparkle.framework가 없습니다." "no-sparkle"

step "4/6 서명"
# 서명 신원이 바뀌면 키체인은 이걸 '다른 앱'으로 보고 접근 권한을 다시 묻는다.
# ad-hoc 서명은 코드가 한 줄만 바뀌어도 해시가 달라지므로 빌드할 때마다
# 비밀번호 창이 뜬다. 그 창은 모달이라 키보드를 통째로 잡는다.
# Developer ID가 있으면 신원이 고정되므로 "항상 허용"이 계속 유지된다.
SIGN_ID="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/')"
fi
if [ -n "$SIGN_ID" ]; then
  echo "서명 신원: $SIGN_ID (고정 신원 - 키체인 권한 유지됨)"
else
  SIGN_ID="-"
  echo "경고: Developer ID 인증서가 없어 임시(ad-hoc) 서명합니다."
  echo "      빌드할 때마다 키체인 비밀번호를 다시 물어볼 수 있습니다."
fi
codesign --force --deep --sign "$SIGN_ID" "$STAGE" || fail "코드 서명 실패" "codesign"
codesign --verify --deep --strict "$STAGE" || fail "코드 서명 검증 실패" "codesign-verify"

step "5/6 설치"
# osascript(애플 이벤트)는 절대 쓰지 않는다. 백그라운드에서 실행하면 macOS가
# "제어를 허용하시겠습니까?" 모달을 띄우고, 그 창이 키보드 입력을 통째로
# 가로챈다. 신호를 직접 보내는 방식은 어떤 권한 창도 띄우지 않는다.
pkill -x "$EXE" >/dev/null 2>&1
sleep 1
pkill -9 -x "$EXE" >/dev/null 2>&1
sleep 1
rm -rf "/Applications/CCMB.app"
ditto "$STAGE" "/Applications/CCMB.app" || fail "/Applications 설치 실패" "install"
xattr -dr com.apple.quarantine "/Applications/CCMB.app" 2>/dev/null

step "6/6 실행"
LAUNCH_AT="$(date '+%Y-%m-%d %H:%M:%S')"
# -g(백그라운드)를 쓰지 않는다. 키체인 접근 대화상자가 떠야 할 때 그 창이
# 다른 창 뒤에 숨어버려서, 키보드만 먹통이고 이유는 안 보이는 상황이 된다.
open -n "/Applications/CCMB.app" || fail "앱 실행 실패" "launch"
sleep 6
if ! pgrep -x "$EXE" >/dev/null; then
  printf '\n--- dyld/실행 오류 ---\n'
  "/Applications/CCMB.app/Contents/MacOS/$EXE" 2>&1 | head -20
  fail "앱이 실행 직후 종료되었습니다." "crash"
fi

printf '실행 중: '; pgrep -lx "$EXE"

step "인증 대화상자 확인"
# 이게 떠 있으면 키보드가 잡힌 상태다. 원인을 눈에 보이게 남긴다.
if pgrep -lf SecurityAgent >/dev/null 2>&1; then
  echo "주의: 키체인/인증 대화상자가 떠 있습니다. 화면에서 응답해야 키보드가 돌아옵니다."
  pgrep -lf SecurityAgent
else
  echo "인증 대화상자 없음"
fi

step "CPU 폭주 검사"
# 블로킹만 보면 안 된다. 이벤트 루프를 놓지 않고 도는 폭주도 메뉴가 열린
# 상태에서는 똑같이 키보드를 잡는다.
CPU_SUM=0
for i in 1 2 3 4 5; do
  C="$(ps -o %cpu= -p "$(pgrep -x "$EXE" | head -1)" 2>/dev/null | tr -d ' ')"
  [ -n "$C" ] || C=0
  echo "  표본 $i: ${C}%"
  CPU_SUM="$(python3 -c "print($CPU_SUM + $C)")"
  sleep 1
done
CPU_AVG="$(python3 -c "print(round($CPU_SUM/5, 1))")"
echo "평균 CPU: ${CPU_AVG}%"
if python3 -c "import sys; sys.exit(0 if $CPU_AVG > 25 else 1)"; then
  pkill -9 -x "$EXE" 2>/dev/null
  fail "유휴 상태에서 CPU ${CPU_AVG}% - 폭주로 판단하고 앱을 종료했습니다." "cpu-spin"
fi

step "메인 스레드 건강 검사"
# 메뉴바 앱의 메인 스레드가 막히면 macOS 전체 키보드 입력이 멎는다.
# 실행 직후 2초간 표본을 떠서 메인 스레드가 블로킹 대기 중이 아닌지 확인한다.
SAMPLE="/tmp/ccmb-mainthread.txt"
sample "$EXE" 2 -file "$SAMPLE" >/dev/null 2>&1
if [ -f "$SAMPLE" ]; then
  if grep -qE "semaphore_wait|dispatch_group_wait|_dispatch_sync|AndWait" "$SAMPLE"; then
    echo "경고: 메인 스레드가 블로킹 대기 중일 수 있습니다."
    grep -nE "semaphore_wait|dispatch_group_wait|_dispatch_sync|AndWait" "$SAMPLE" | head -5
    pkill -9 -x "$EXE" 2>/dev/null
    fail "메인 스레드 블로킹이 감지되어 앱을 종료했습니다." "mainthread-block"
  fi
  echo "메인 스레드 정상 (블로킹 대기 없음)"
else
  echo "표본 수집 실패 - 검사 건너뜀"
fi
printf '\n--- 앱 내부 로그 (os_log) ---\n'
log show --predicate 'subsystem == "com.codex.creditmenubar"' --start "$LAUNCH_AT" --style compact 2>/dev/null | tail -n 40

printf '\nCCMB_RESULT=OK\n'
