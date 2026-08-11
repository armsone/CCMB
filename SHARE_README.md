# CCMB 설치 및 사용 안내

CCMB는 macOS 메뉴바에서 Codex 크레딧을 확인하는 작은 앱입니다.

## 친구가 사용하기 전에 필요한 것

- macOS 10.15 Catalina 이상
- Codex CLI 설치(설치 방식에 따라 Node.js 필요)
- 친구 본인의 OpenAI/Codex 계정 로그인

## 설치

1. `CCMB.dmg`를 엽니다.
2. `CCMB.app`을 `Applications` 폴더로 드래그합니다.
3. `Applications` 폴더에서 `CCMB.app`을 실행합니다.
4. 메뉴바 오른쪽에 아이콘과 크레딧 숫자가 나타납니다.

## 업데이트

새 버전의 `CCMB.dmg`를 받은 경우 실행 중인 CCMB를 먼저 종료합니다. 새 DMG를 열고 `CCMB.app`을 `Applications` 폴더로 다시 드래그한 다음, 기존 앱을 대치할지 묻는 창에서 `대치`를 선택합니다.

## Codex CLI 준비

친구 맥에서 터미널을 열고 아래 명령이 작동해야 합니다.

```sh
codex --version
codex login status
codex app-server --help
```

`codex` 명령을 찾지 못하거나 로그인 상태가 아니면 Codex CLI를 설치하고 `codex login`을 실행해야 합니다.

## 실행되지 않을 때

1. macOS가 13 이상인지 확인합니다.
2. 터미널에서 `codex --version`과 `codex login status`가 정상 동작하는지 확인합니다.
3. CCMB를 종료하고 `Applications` 폴더에서 다시 실행합니다.
4. 계속 문제가 생기면 사용한 macOS 버전과 표시된 오류 메시지를 CCMB 배포자에게 전달합니다.

## 앱에서 보는 정보

- 메뉴바 남은 주간 사용량과 0보다 큰 크레딧, 예: `74%,1105` 또는 `74%,0.49`; Spark 사용량과 0 크레딧은 메뉴바에 표시하지 않음
- 주간 사용량
- Spark 모델별 사용량
- 크레딧 상세값, 소수점 4자리
- 리셋 크레딧
- 초기화 시간
- 가져온 시간
- 새로고침 버튼과 다음 자동 갱신까지 남은 시간
- 자동 갱신 간격: 끔, 30초, 1분, 5분(선택값 유지)
- 계정 이메일

## 다른 앱이나 Codex 채팅에서 사용량 보기

CCMB는 정상적으로 가져온 최신 값을 다음 파일에 저장합니다.

```text
~/Library/Application Support/CCMB/usage-v1.json
```

메뉴바에서 `다른 채팅과 공유`를 열면 저장 위치와 공유 상태를 볼 수 있습니다. `채팅 요청문 복사`를 누른 뒤 다른 Codex 채팅에 붙여넣으면 됩니다.

직접 요청하려면 다른 채팅에 아래처럼 입력합니다.

```text
~/.codex/bin/ccmb-usage를 실행해서 CCMB의 남은 주간 사용량과 크레딧을 알려줘. fresh가 false면 오래된 데이터라고 말해줘.
```

터미널에서 직접 확인할 수도 있습니다.

```sh
~/.codex/bin/ccmb-usage
```

원본을 다시 조회해서 저장값과 비교하려면 다음 명령을 사용합니다.

```sh
~/.codex/bin/ccmb-usage --verify-live
```

결과의 `fresh`, `fetchedAt`, `ageSeconds`, `origin`, `evidence`가 데이터의 최신성과 출처를 설명합니다. 로그인 토큰과 인증정보는 공유 파일에 저장하지 않습니다.

## 자동 시작과 재실행

- 메뉴에서 `자동시작`을 켜면 다음 로그인/재시작 후 자동 실행됩니다.
- CCMB가 이미 실행 중인 상태에서 다시 실행되면 기존 실행본을 정리하고 새 실행본만 남깁니다.
- 맥이 잠자기에서 깨어나면 Codex 연결을 다시 시작하고, 복구에 실패할 때만 CCMB를 다시 실행합니다.

## 주의

친구에게 보낼 파일은 `Developer ID`로 서명하고 Apple 공증을 받은 `CCMB.dmg`여야 합니다. `CCMB.app`을 직접 압축해서 보내면 macOS에서 "손상되었기 때문에 열 수 없습니다"라고 차단될 수 있습니다.
