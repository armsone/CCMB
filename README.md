# CCMB Android (v0.8.2)

사용자 설정 NAS 및 로컬 파일에 모인 AI 코딩 어시스턴트(Codex, Claude, Gemini)의 사용량과 24시간 소비 그래프를 모니터링하는 네이티브 Android 애플리케이션입니다.

iPhone 네이티브 앱의 승인된 레이아웃, 기하학, 4대 테마, 데이터 계약 및 날짜/차트 의미론을 Kotlin과 Jetpack Compose로 구현한 네이티브 포팅 버전입니다.

---

## 주요 기능 및 아키텍처

1. **상태 라우팅 및 장애 복구 (cap_source_routing / cap_app_lifecycle)**
   - `Welcome`, `Loading`, `Loaded`, `Failed` 4-상태 전이 라우터
   - 비동기 경쟁 방지 `generation` 카운터 제어
   - 네트워크 오류 시 마지막 정상값(`Last-Known`) 보존 및 배너 안내
   - 포그라운드 복귀 시 자동 갱신 재개, 백그라운드 전환 시 타이머 일시 정지 (`FLAG_KEEP_SCREEN_ON` 지원)
   - 포그라운드 날씨 정보 180초 주기 자동 갱신

2. **NAS 전용 인증 및 통신 프로토콜 (cap_nas_auth_flow / cap_nas_v2_transport / cap_nas_legacy_transport)**
   - 전용 WebView 시트 모달을 통한 사용자 정의 NAS 웹 로그인
   - 세션 쿠키 추출 및 세션 인증 검증을 통한 안전한 연결
   - 앱 내부에서 비밀번호 및 민감 자격증명 직접 저장 배제
   - v2 스냅샷 엔드포인트 및 새로고침 작업 요청 처리
   - 구형 NAS 대상 명시적 HTTP 404 시 레거시 폴백 지원

3. **로컬 파일 가져오기 및 지속성 (cap_file_provider_saf)**
   - Android Storage Access Framework(SAF) `ACTION_OPEN_DOCUMENT` 지원
   - `takePersistableUriPermission`을 통한 읽기 권한 지속화
   - Mac `usage-v1.json` (schemaVersion 1) 및 NAS 스냅샷 JSON 파싱 지원
   - SharedPreferences에 URI 및 파일 출처 영속화, 앱 재실행 시 자동 재읽기
   - UI에서 원클릭으로 기본 NAS 모드로 복귀 가능 (`store.useNAS()`)

4. **승인된 대시보드 기하학 및 서비스 메트릭 (cap_dashboard_card_geometry / cap_service_*)**
   - 3개 서비스 고정 순서: Codex → Claude → Gemini (본계정/부계정/세 번째 계정)
   - 232dp 고정 폭 3열 쿼터 블록 (76.67dp 열 너비)
   - **Codex**: 1열 단일 '리셋권 N개' 헤더 + 상위 2개 만료 일시(8.5sp), 2열 주간 24sp, 3열 토큰 16sp 볼드
   - **Claude**: 1열 Fable 주간 %, 2열 5시간 세션 %, 3열 전체 주간 %, 하단 세션 게이지 바
   - **Gemini**: 1열 빈칸(구분선 투명), 2열 세션 %, 3열 주간 %, 3개 계정 고유 색상 테두리 및 오리지널 Gemini 로고 적용
   - 대형 4자리 플립 시계 및 하단 날짜 표시

5. **24시간 Canvas 벡터 차트 (cap_history_bin_math / cap_history_canvas_plot)**
   - 30분 단위 로컬 벽시계 버킷 집계 및 UTC 경계 정렬
   - x=0 최신(좌측) ~ x=width 24시간 전(우측) 시간축 매핑
   - 미수집 구간 단절 보존 (가짜 0 채움 금지), 실제 최고치/절반/0 기준 수평 격자선, 수직 그라데이션 면적 채움, 부분 표본 중공원(hollow marker)

6. **4대 테마 시스템 (cap_theme_system)**
   - 병기스타일 4종 테마: Light(라이트), Friday(프라이데이), Jarvis(자비스), Ultron(울트론)
   - 원클릭 테마 순환 및 길게 누름 시 Dropdown 선택 메뉴 제공
   - 벡터 Compose Canvas 기반 테마 아이콘 렌더링

7. **기기 적응형 윈도우 및 TV 지원 (cap_tablet_adaptive_layout)**
   - **스마트폰**: 가용 세로 높이를 계산하여 그래프 높이로 분배함으로써 하단 빈 여백 해소
   - **태블릿**:
     - 가로 모드: 좌측(Codex, Claude) - 중앙(플립 시계, 현재/시간별 7개/일별 7개 날씨) - 우측(Gemini 3계정) 3단 레이아웃
     - 세로 모드: 6개 균등 카드 2x3 그리드 배치
   - **Google TV / Leanback**: `UiModeManager.currentModeType == UI_MODE_TYPE_TELEVISION` 감지 시 전용 레이아웃 분기, D-pad 리모컨 포커스 강조 테두리(`accent` 2dp) 및 와이드 배너(`@drawable/tv_banner`) 지원 (기존 앱 레벨 구현 상태이며 실제 물리 기기 검증은 미수행)

8. **디버그 전용 카탈로그 모드**
   - Intent Extra `ccmb_catalog="populated"`를 통해 디버그 빌드(`BuildConfig.DEBUG`)에서만 독립된 합성 픽스처 구동
   - 릴리스 빌드에서는 원천 차단되며 일반 사용자 경로는 절대 픽스처를 사용하지 않음
   - 상단에 `샘플 미리보기 (디버그 카탈로그 모드)` 배너 표시
   - 디버그 테마 미리보기: `ccmb_theme="jarvis"` 인텐트 전달 시 설정 저장 없이 즉각 테마 미리보기 적용

---

## 빌드 및 실행 가이드

본 프로젝트는 표준 환경변수(`JAVA_HOME`, `ANDROID_HOME` 등)와 Gradle 래퍼를 사용하여 빌드할 수 있습니다.

### 디버그 APK 빌드 명령
```bash
./gradlew :app:assembleDebug --offline --no-daemon
```

### 디버그 카탈로그 모드 진입 명령
```bash
adb shell am start -n com.armsone.ccmb/.MainActivity --es ccmb_catalog populated
```

### 정상 모드로 복귀 명령
```bash
adb shell am start -n com.armsone.ccmb/.MainActivity
```

---

## 구현 범위 및 지원 안내

- **데이터 소스 지원**: 사용자 설정 NAS 및 로컬 파일(SAF) 방식을 지원합니다.
- **CloudKit 미구현**: iOS 전용 CloudKit 프레임워크 연동은 안드로이드에 구현되어 있지 않으며, NAS 및 로컬 파일 데이터 소스를 기본으로 사용합니다.
- **Google TV 지원 현황**: TV용 Leanback UI 모드 감지 및 네비게이션 코드가 앱 내에 구현되어 있으나, 실제 물리 기기 환경에서의 검증은 완료되지 않았습니다.
