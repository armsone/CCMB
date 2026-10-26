package com.armsone.ccmb.ui

import android.app.Activity
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.onLongClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import com.armsone.ccmb.LocalIsTV
import com.armsone.ccmb.format.CCMBFormat
import com.armsone.ccmb.model.Account24hModel
import com.armsone.ccmb.model.PreferredSource
import com.armsone.ccmb.model.Service
import com.armsone.ccmb.model.ServiceUsage
import com.armsone.ccmb.model.UsageSnapshot
import com.armsone.ccmb.store.SnapshotStore
import com.armsone.ccmb.store.WeatherReading
import com.armsone.ccmb.store.WeatherStore
import com.armsone.ccmb.theme.CCMBAppearance
import com.armsone.ccmb.theme.CCMBTheme
import com.armsone.ccmb.theme.LocalCCMBPalette
import kotlin.math.max
import kotlin.math.min

@Composable
fun DashboardScreen(
    snapshot: UsageSnapshot,
    store: SnapshotStore,
    weatherStore: WeatherStore,
    currentTheme: CCMBAppearance,
    onSelectTheme: (CCMBAppearance) -> Unit,
    onSelectService: (ServiceUsage) -> Unit,
    onOpenFilePicker: () -> Unit = {},
    isCatalogMode: Boolean = false,
    onRequestWeather: () -> Unit = {},
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current
    val weatherReading by weatherStore.reading.collectAsState()
    val refreshProblem by store.refreshProblem.collectAsState()
    val nasNeedsLogin by store.nasNeedsLogin.collectAsState()
    val nasBusy by store.nasRefreshBusy.collectAsState()
    val currentSource by store.displayedSource.collectAsState()
    val isTV = LocalIsTV.current

    // 어두운 팔레트에서는 상태바/내비게이션바 아이콘을 밝게, 밝은 팔레트에서는 어둡게.
    // 테마 전환 시 palette.isDark 가 바뀌면 다시 적용된다. (UI 전용, 다른 로직 없음)
    val view = LocalView.current
    val isDarkPalette = palette.isDark
    if (!view.isInEditMode) {
        SideEffect {
            (view.context as? Activity)?.window?.let { window ->
                val controller = WindowCompat.getInsetsController(window, view)
                controller.isAppearanceLightStatusBars = !isDarkPalette
                controller.isAppearanceLightNavigationBars = !isDarkPalette
            }
        }
    }

    val cardServices = listOf(
        Service.CODEX,
        Service.CLAUDE,
        Service.GEMINI,
        Service.GEMINI2,
        Service.GEMINI3
    ).filter { snapshot.services[it] != null }

    BoxWithConstraints(
        modifier = modifier
            .fillMaxSize()
            .background(
                brush = Brush.verticalGradient(
                    colors = listOf(palette.bg, palette.surface2)
                )
            ),
        contentAlignment = Alignment.TopCenter
    ) {
        // BoxWithConstraints는 edge-to-edge 창 전체 높이를 주므로, 아래 Column이 먹는
        // 상태바/내비게이션바 inset을 빼야 카드가 실제 보이는 높이에 맞는다.
        val statusInset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
        val navInset = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
        val availableHeight = maxHeight - statusInset - navInset
        val isTablet = maxWidth >= 600.dp && !isTV
        val density = LocalDensity.current
        val isLargeFont = density.fontScale > 1.3f

        val contentMaxWidth = if (isTV) 640.dp else 480.dp

        if (isTablet) {
            TabletDashboard(
                snapshot = snapshot,
                store = store,
                weatherStore = weatherStore,
                currentTheme = currentTheme,
                onSelectTheme = onSelectTheme,
                onSelectService = onSelectService,
                onOpenFilePicker = onOpenFilePicker,
                onRequestWeather = onRequestWeather,
                isCatalogMode = isCatalogMode,
                modifier = Modifier
                    .fillMaxSize()
                    .statusBarsPadding()
                    .navigationBarsPadding()
                    .padding(horizontal = 12.dp, vertical = 6.dp)
            )
        } else {
            // Adaptive layout: phone fit / TV max 640dp
            Column(
                modifier = Modifier
                    .widthIn(max = contentMaxWidth)
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .navigationBarsPadding()
                    .padding(horizontal = 12.dp, vertical = 4.dp)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                // Header
                DashboardHeader(
                    snapshot = snapshot,
                    store = store,
                    weather = weatherReading,
                    currentTheme = currentTheme,
                    onSelectTheme = onSelectTheme,
                    onOpenFilePicker = onOpenFilePicker,
                    onRequestWeather = onRequestWeather
                )

                // Local file mode banner with one-tap switch back to NAS
                if (currentSource == PreferredSource.FILE) {
                    BannerCard(
                        text = "로컬 파일 (${store.sourceFileName.value ?: "JSON"}) 사용 중 · NAS로 전환하려면 탭하세요",
                        isWarning = false,
                        accentColor = palette.accent,
                        onClick = { store.useNAS() }
                    )
                }

                // Catalog mode indicator badge
                if (isCatalogMode) {
                    BannerCard(
                        text = "샘플 미리보기 (디버그 카탈로그 모드)",
                        isWarning = false,
                        accentColor = palette.accent
                    )
                }

                // NAS busy banner
                if (nasBusy || snapshot.collectionBusy) {
                    BannerCard(
                        text = "NAS가 지금 수집 중입니다. 끝나면 다음 새로 고침에 반영됩니다.",
                        isWarning = false
                    )
                }

                // Auth error or regular error banner
                if (nasNeedsLogin && currentSource == PreferredSource.NAS) {
                    val loginMsg = refreshProblem ?: "NAS에 다시 로그인해 주세요."
                    BannerCard(
                        text = "$loginMsg · 탭하여 NAS 로그인",
                        isWarning = true,
                        onClick = { store.requestNASLogin() }
                    )
                } else if (refreshProblem != null) {
                    BannerCard(
                        text = refreshProblem!!,
                        isWarning = true
                    )
                }

                // Calculate card heights
                val hasErrorBanner = (nasNeedsLogin && currentSource == PreferredSource.NAS) || (refreshProblem != null)
                val bannerCount = (if (isCatalogMode) 1 else 0) +
                        (if (currentSource == PreferredSource.FILE) 1 else 0) +
                        (if (nasBusy || snapshot.collectionBusy) 1 else 0) +
                        (if (hasErrorBanner) 1 else 0)

                val heights = calculateCardHeights(
                    services = cardServices,
                    availableHeight = availableHeight,
                    bannerCount = bannerCount,
                    isTablet = isTablet,
                    isLargeFont = isLargeFont
                )

                // Cards stack
                cardServices.forEachIndexed { index, service ->
                    val usage = snapshot.services[service]
                    if (usage != null) {
                        val historyModel = remember(snapshot.consumptionHistory, service) {
                            snapshot.consumptionHistory?.let { hist ->
                                val codexWeeklyRemain = snapshot.services[Service.CODEX]?.weeklyWindow?.remainingPercent ?: 1.0
                                val codexBalance = snapshot.services[Service.CODEX]?.creditBalance ?: 0.0
                                val codexUsesCredits = (codexWeeklyRemain <= 0.0) && (codexBalance > 0.0)

                                val usesCredits = service == Service.CODEX && codexUsesCredits
                                val points = hist.seriesFor(service, codexUsesCredits = usesCredits)
                                val unit = if (usesCredits) "토큰" else "%"
                                Account24hModel.create(
                                    samples = points,
                                    anchorDate = snapshot.newestFetchedAt ?: java.util.Date(),
                                    usesCreditsScale = usesCredits,
                                    unit = unit,
                                    color = CCMBTheme.serviceTint(service)
                                )
                            }
                        }

                        AccountCardView(
                            usage = usage,
                            historyModel = historyModel,
                            cardHeight = heights?.getOrNull(index),
                            onSelect = { onSelectService(usage) }
                        )
                    }
                }

                Spacer(modifier = Modifier.height(12.dp))
            }
        }
    }
}

private fun calculateCardHeights(
    services: List<Service>,
    availableHeight: Dp,
    bannerCount: Int,
    isTablet: Boolean,
    isLargeFont: Boolean
): List<Dp>? {
    if (isLargeFont || services.isEmpty()) return null

    val weights = services.map { referenceHeight(it) }
    // Column 실제 구성: 세로 padding 4+4, 헤더 64(2+36+24+2), 8dp 간격 × (헤더·배너·카드·꼬리 Spacer 사이),
    // 배너 추정 58, 꼬리 Spacer 12. inset은 availableHeight에서 이미 뺐다.
    val columnPadding = 8.dp
    val headerHeight = 64.dp
    val sectionGap = 8.dp
    val estimatedBannerHeight = 58.dp
    val trailingSpacer = 12.dp
    val gapCount = services.size + bannerCount + 1
    val overhead = columnPadding + headerHeight + trailingSpacer +
            sectionGap * gapCount + estimatedBannerHeight * bannerCount

    val availableForCards = availableHeight - overhead
    val sumWeights = weights.sumOf { it.value.toDouble() }
    val fit = max(0.82, availableForCards.value.toDouble() / max(1.0, sumWeights))

    // Phone removes 1.12 maxscale ceiling so graphs fill remaining vertical height without blank footer gap!
    // Tablet keeps 1.12 ceiling to avoid overstretching on large screens.
    val scale = if (!isTablet) fit else min(1.12, fit)

    return services.zip(weights).map { (service, weight) ->
        max(weight.value * scale.toFloat(), minimumHeight(service).value).dp
    }
}

private fun referenceHeight(service: Service): Dp = when (service) {
    Service.CODEX -> 165.dp
    Service.CLAUDE -> 165.dp
    Service.GEMINI, Service.GEMINI2, Service.GEMINI3 -> 158.dp
    Service.GROK -> 144.dp
}

// 카드 160dp = 세로 padding 20 + 상단 행 66 + 간격 4 + 플롯 70 (그래프 행 54 ≈ y축 라벨 3줄·타임라인 16 포함).
// 이전 144dp 는 플롯이 42dp 뿐이라 그래프 행 18dp 로 납작해지고 y축 라벨이 겹쳤다.
// 5카드+배너가 한 화면에 못 들어가면 짧게 스크롤되는 쪽을 택한다(그래프 가독성 우선).
private fun minimumHeight(service: Service): Dp = 160.dp

@Composable
private fun DashboardHeader(
    snapshot: UsageSnapshot,
    store: SnapshotStore,
    weather: WeatherReading?,
    currentTheme: CCMBAppearance,
    onSelectTheme: (CCMBAppearance) -> Unit,
    onOpenFilePicker: () -> Unit = {},
    onRequestWeather: () -> Unit = {},
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current
    var showThemeMenu by remember { mutableStateOf(false) }
    var showSourceMenu by remember { mutableStateOf(false) }

    // pointerInput(Unit) 의 제스처 코루틴은 최초 컴포지션의 currentTheme/onSelectTheme 을 붙잡고
    // 재시작되지 않으므로, 탭마다 "최초 테마의 next" 만 반복 선택되는 버그가 있었다(예: 항상 FRIDAY).
    // rememberUpdatedState 로 최신 값을 읽게 하면 제스처 감지를 재시작하지 않고도 4개 테마가 계속 순환한다.
    val latestTheme by rememberUpdatedState(currentTheme)
    val latestOnSelectTheme by rememberUpdatedState(onSelectTheme)

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 4.dp, vertical = 2.dp)
    ) {
        // Line 1: Title + Refresh Control + Theme Icon
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(36.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text(
                text = "CCMB",
                fontSize = 24.sp,
                fontWeight = FontWeight.Bold,
                color = palette.text
            )

            Row(verticalAlignment = Alignment.CenterVertically) {
                CompactRefreshControl(store = store)

                Box {
                    // 44dp 정사각 터치 영역. 36dp 헤더 행 안에서는 위아래 4dp 씩 넘치며 가운데 정렬되고
                    // (requiredSize), 행 높이/헤더 64dp 산식은 그대로 유지된다.
                    Box(
                        modifier = Modifier
                            .requiredSize(44.dp)
                            .semantics {
                                role = Role.Button
                                contentDescription = "테마 ${currentTheme.displayName}. 탭하면 다음 테마, 길게 누르면 목록"
                                onClick {
                                    latestOnSelectTheme(latestTheme.next)
                                    true
                                }
                                onLongClick {
                                    showThemeMenu = true
                                    true
                                }
                            }
                            .pointerInput(Unit) {
                                detectTapGestures(
                                    onTap = { latestOnSelectTheme(latestTheme.next) },
                                    onLongPress = { showThemeMenu = true }
                                )
                            },
                        contentAlignment = Alignment.Center
                    ) {
                        CCMBThemeIcon(appearance = currentTheme)
                    }

                    DropdownMenu(
                        expanded = showThemeMenu,
                        onDismissRequest = { showThemeMenu = false }
                    ) {
                        CCMBAppearance.entries.forEach { appearance ->
                            DropdownMenuItem(
                                text = {
                                    Row(
                                        horizontalArrangement = Arrangement.SpaceBetween,
                                        verticalAlignment = Alignment.CenterVertically,
                                        modifier = Modifier.fillMaxWidth()
                                    ) {
                                        Text(appearance.displayName)
                                        if (appearance == currentTheme) {
                                            Icon(
                                                imageVector = Icons.Default.Check,
                                                contentDescription = null,
                                                tint = palette.accent,
                                                modifier = Modifier.size(16.dp)
                                            )
                                        }
                                    }
                                },
                                onClick = {
                                    onSelectTheme(appearance)
                                    showThemeMenu = false
                                }
                            )
                        }
                    }
                }
            }
        }

        // Line 2: Weather (left) & Sync time (center/right) with source switch menu
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(24.dp),
            contentAlignment = Alignment.CenterStart
        ) {
            // Weather: 측정값이 있으면 날씨 기호 + 실제 기온, 없으면 기온을 꾸며내지 않고
            // 소형 '날씨' 버튼만 보여 onRequestWeather(권한/조회는 호출측 소관)를 부른다.
            if (weather != null) {
                val conditionLabel = weatherConditionLabel(weather.symbolName)
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.semantics {
                        contentDescription = "현재 기온 ${weather.temperature.toInt()}도, $conditionLabel"
                    }
                ) {
                    WeatherSymbolIcon(
                        symbolName = weather.symbolName,
                        tint = palette.muted,
                        size = 24.dp
                    )
                    Spacer(modifier = Modifier.width(4.dp))
                    Text(
                        text = "${weather.temperature.toInt()}°",
                        fontSize = 18.sp,
                        fontFamily = FontFamily.Monospace,
                        color = palette.muted
                    )
                }
            } else {
                Row(
                    modifier = Modifier
                        .clip(RoundedCornerShape(6.dp))
                        .clickable(onClick = onRequestWeather)
                        .padding(horizontal = 6.dp, vertical = 2.dp)
                        .semantics {
                            role = Role.Button
                            contentDescription = "날씨 보기"
                        },
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    WeatherSymbolIcon(
                        symbolName = "cloud_sun",
                        tint = palette.muted,
                        size = 14.dp
                    )
                    Spacer(modifier = Modifier.width(4.dp))
                    Text(
                        text = "날씨",
                        fontSize = 13.5.sp,
                        color = palette.muted
                    )
                }
            }

            // Sync View (center) with source switch dropdown
            Box(
                modifier = Modifier.fillMaxWidth(),
                contentAlignment = Alignment.Center
            ) {
                Row(
                    modifier = Modifier
                        .clip(RoundedCornerShape(6.dp))
                        .clickable { showSourceMenu = true }
                        .padding(horizontal = 6.dp, vertical = 2.dp)
                        .semantics {
                            val source = if (store.displayedSource.value == com.armsone.ccmb.model.PreferredSource.NAS) "NAS" else "Mac"
                            contentDescription = "$source 동기화 ${CCMBFormat.macCollectionTime(snapshot.newestFetchedAt)}"
                        },
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    val dotColor = if (snapshot.isStale()) CCMBTheme.signalRed else Color(0xFF12BD8C)
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .clip(CircleShape)
                            .background(dotColor)
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    val sourcePrefix = if (store.displayedSource.value == com.armsone.ccmb.model.PreferredSource.FILE) "파일 " else ""
                    Text(
                        text = "${sourcePrefix}동기화 ${CCMBFormat.macCollectionTime(snapshot.newestFetchedAt)}",
                        fontSize = 13.5.sp,
                        color = palette.muted
                    )
                }

                DropdownMenu(
                    expanded = showSourceMenu,
                    onDismissRequest = { showSourceMenu = false }
                ) {
                    DropdownMenuItem(
                        text = { Text("NAS에서 새로 고침") },
                        onClick = {
                            showSourceMenu = false
                            store.useNAS()
                        }
                    )
                    if (store.displayedSource.value == PreferredSource.NAS) {
                        DropdownMenuItem(
                            text = { Text("NAS 로그인") },
                            onClick = {
                                showSourceMenu = false
                                store.requestNASLogin()
                            }
                        )
                    }
                    DropdownMenuItem(
                        text = { Text("로컬 파일(JSON) 가져오기") },
                        onClick = {
                            showSourceMenu = false
                            onOpenFilePicker()
                        }
                    )
                }
            }
        }
    }
}

/** WeatherReading.symbolName(sun/cloud_sun/cloud/fog/drizzle/rain/snow/thunder) → 접근성용 한글 설명. */
private fun weatherConditionLabel(symbolName: String): String = when (symbolName) {
    "sun" -> "맑음"
    "cloud_sun" -> "구름 조금"
    "cloud" -> "흐림"
    "fog" -> "안개"
    "drizzle" -> "이슬비"
    "rain" -> "비"
    "snow" -> "눈"
    "thunder" -> "뇌우"
    else -> "흐림"
}

@Composable
fun BannerCard(
    text: String,
    isWarning: Boolean,
    accentColor: Color? = null,
    onClick: (() -> Unit)? = null,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current
    val tint = accentColor ?: if (isWarning) palette.danger else palette.accent

    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(palette.card)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = if (isWarning) Icons.Default.Warning else Icons.Default.Info,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(20.dp)
        )
        Spacer(modifier = Modifier.width(10.dp))
        Text(
            text = text,
            fontSize = 12.5.sp,
            color = palette.text
        )
    }
}
