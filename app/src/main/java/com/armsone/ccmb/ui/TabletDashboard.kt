package com.armsone.ccmb.ui

import android.content.res.Configuration
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.onLongClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.armsone.ccmb.format.CCMBFormat
import com.armsone.ccmb.model.Account24hModel
import com.armsone.ccmb.model.PreferredSource
import com.armsone.ccmb.model.Service
import com.armsone.ccmb.model.ServiceUsage
import com.armsone.ccmb.model.UsageSnapshot
import com.armsone.ccmb.store.DailyForecast
import com.armsone.ccmb.store.HourlyForecast
import com.armsone.ccmb.store.SnapshotStore
import com.armsone.ccmb.store.WeatherReading
import com.armsone.ccmb.store.WeatherStore
import com.armsone.ccmb.theme.CCMBAppearance
import com.armsone.ccmb.theme.CCMBTheme
import com.armsone.ccmb.theme.LocalCCMBPalette
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt

@Composable
fun TabletDashboard(
    snapshot: UsageSnapshot,
    store: SnapshotStore,
    weatherStore: WeatherStore,
    currentTheme: CCMBAppearance,
    onSelectTheme: (CCMBAppearance) -> Unit,
    onSelectService: (ServiceUsage) -> Unit,
    onOpenFilePicker: () -> Unit,
    onRequestWeather: () -> Unit,
    isCatalogMode: Boolean,
    modifier: Modifier = Modifier
) {
    val configuration = LocalConfiguration.current
    val isLandscape = configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
    val refreshProblem by store.refreshProblem.collectAsState()
    val nasNeedsLogin by store.nasNeedsLogin.collectAsState()
    val nasBusy by store.nasRefreshBusy.collectAsState()
    val currentSource by store.displayedSource.collectAsState()
    val palette = LocalCCMBPalette.current

    Column(modifier = modifier) {
        // Top Header: Title, sync status, refresh button, theme switch
        TabletTopHeader(
            snapshot = snapshot,
            store = store,
            currentTheme = currentTheme,
            onSelectTheme = onSelectTheme,
            onOpenFilePicker = onOpenFilePicker
        )

        // Banners if needed
        if (currentSource == PreferredSource.FILE) {
            Spacer(modifier = Modifier.height(4.dp))
            BannerCard(
                text = "로컬 파일 (${store.sourceFileName.value ?: "JSON"}) 사용 중 · NAS로 전환하려면 탭하세요",
                isWarning = false,
                accentColor = palette.accent,
                onClick = { store.useNAS() }
            )
        }
        if (isCatalogMode) {
            Spacer(modifier = Modifier.height(4.dp))
            BannerCard(
                text = "샘플 미리보기 (디버그 카탈로그 모드)",
                isWarning = false,
                accentColor = palette.accent
            )
        }
        if (nasBusy || snapshot.collectionBusy) {
            Spacer(modifier = Modifier.height(4.dp))
            BannerCard(
                text = "NAS가 지금 수집 중입니다. 끝나면 다음 새로 고침에 반영됩니다.",
                isWarning = false
            )
        }
        if (nasNeedsLogin && currentSource == PreferredSource.NAS) {
            Spacer(modifier = Modifier.height(4.dp))
            val loginMsg = refreshProblem ?: "NAS에 다시 로그인해 주세요."
            BannerCard(
                text = "$loginMsg · 탭하여 NAS 로그인",
                isWarning = true,
                onClick = { store.requestNASLogin() }
            )
        } else if (refreshProblem != null) {
            Spacer(modifier = Modifier.height(4.dp))
            BannerCard(
                text = refreshProblem!!,
                isWarning = true
            )
        }

        Spacer(modifier = Modifier.height(6.dp))

        // Adaptive tablet layout
        if (isLandscape) {
            TabletLandscapeDashboard(
                snapshot = snapshot,
                weatherStore = weatherStore,
                onSelectService = onSelectService,
                onRequestWeather = onRequestWeather,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
            )
        } else {
            TabletPortraitDashboard(
                snapshot = snapshot,
                weatherStore = weatherStore,
                onSelectService = onSelectService,
                onRequestWeather = onRequestWeather,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
            )
        }
    }
}

@Composable
private fun TabletTopHeader(
    snapshot: UsageSnapshot,
    store: SnapshotStore,
    currentTheme: CCMBAppearance,
    onSelectTheme: (CCMBAppearance) -> Unit,
    onOpenFilePicker: () -> Unit,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current
    var showThemeMenu by remember { mutableStateOf(false) }
    var showSourceMenu by remember { mutableStateOf(false) }

    val latestTheme by rememberUpdatedState(currentTheme)
    val latestOnSelectTheme by rememberUpdatedState(onSelectTheme)

    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(36.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        // App Title
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = "CCMB",
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
                color = palette.text,
                maxLines = 1
            )
            TaskStatusPill(store = store, modifier = Modifier.widthIn(max = 220.dp))
        }

        // Center: Sync info & Source switch
        Box(contentAlignment = Alignment.Center) {
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .clickable { showSourceMenu = true }
                    .padding(horizontal = 8.dp, vertical = 4.dp)
                    .semantics {
                        val source = if (store.displayedSource.value == PreferredSource.NAS) "NAS" else "Mac"
                        contentDescription = "$source 동기화 ${CCMBFormat.macCollectionTime(snapshot.newestFetchedAt)}"
                    },
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
                val sourcePrefix = if (store.displayedSource.value == PreferredSource.FILE) "파일 " else ""
                Text(
                    text = "${sourcePrefix}동기화 ${CCMBFormat.macCollectionTime(snapshot.newestFetchedAt)}",
                    fontSize = 13.sp,
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

        // Right: Refresh button + Theme Switcher
        Row(verticalAlignment = Alignment.CenterVertically) {
            CompactRefreshControl(store = store)

            Box {
                Box(
                    modifier = Modifier
                        .requiredSize(40.dp)
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
}

/**
 * Tablet Landscape:
 * LEFT 35%: Codex (top), Claude (bottom) stacked
 * CENTER 30%: Utility column (flip clock, current weather, hourly, 7-day)
 * RIGHT 35%: Gemini 1, Gemini 2, Gemini 3 equal stacked
 * No blank cells. Full width.
 */
@Composable
private fun TabletLandscapeDashboard(
    snapshot: UsageSnapshot,
    weatherStore: WeatherStore,
    onSelectService: (ServiceUsage) -> Unit,
    onRequestWeather: () -> Unit,
    modifier: Modifier = Modifier
) {
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        // LEFT 35%: Codex top, Claude bottom
        Column(
            modifier = Modifier
                .weight(0.35f)
                .fillMaxHeight(),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                TabletServiceCardItem(
                    service = Service.CODEX,
                    snapshot = snapshot,
                    onSelect = onSelectService
                )
            }
            Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                TabletServiceCardItem(
                    service = Service.CLAUDE,
                    snapshot = snapshot,
                    onSelect = onSelectService
                )
            }
        }

        // CENTER 30%: Utility column flip clock / current / hourly / 7-day
        Box(
            modifier = Modifier
                .weight(0.30f)
                .fillMaxHeight()
        ) {
            TabletUtilityCard(
                weatherStore = weatherStore,
                onRequestWeather = onRequestWeather,
                isLandscape = true,
                modifier = Modifier.fillMaxSize()
            )
        }

        // RIGHT 35%: Gemini 1 / 2 / 3 equal stacked
        Column(
            modifier = Modifier
                .weight(0.35f)
                .fillMaxHeight(),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                TabletServiceCardItem(
                    service = Service.GEMINI,
                    snapshot = snapshot,
                    onSelect = onSelectService
                )
            }
            Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                TabletServiceCardItem(
                    service = Service.GEMINI2,
                    snapshot = snapshot,
                    onSelect = onSelectService
                )
            }
            Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                TabletServiceCardItem(
                    service = Service.GEMINI3,
                    snapshot = snapshot,
                    onSelect = onSelectService
                )
            }
        }
    }
}

/**
 * Tablet Portrait:
 * Six EXACT equal-size cells in 2 columns, 3 rows:
 * Row 1: Weather+Clock / Codex
 * Row 2: Gemini 1 / Claude
 * Row 3: Gemini 2 / Gemini 3
 */
@Composable
private fun TabletPortraitDashboard(
    snapshot: UsageSnapshot,
    weatherStore: WeatherStore,
    onSelectService: (ServiceUsage) -> Unit,
    onRequestWeather: () -> Unit,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        // Row 1: Utility (Weather+Clock) / Codex
        Row(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Box(modifier = Modifier.weight(1f).fillMaxHeight()) {
                TabletUtilityCard(
                    weatherStore = weatherStore,
                    onRequestWeather = onRequestWeather,
                    isLandscape = false,
                    modifier = Modifier.fillMaxSize()
                )
            }
            Box(modifier = Modifier.weight(1f).fillMaxHeight()) {
                TabletServiceCardItem(
                    service = Service.CODEX,
                    snapshot = snapshot,
                    onSelect = onSelectService
                )
            }
        }

        // Row 2: Gemini 1 / Claude (Claude directly beneath Codex)
        Row(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Box(modifier = Modifier.weight(1f).fillMaxHeight()) {
                TabletServiceCardItem(
                    service = Service.GEMINI,
                    snapshot = snapshot,
                    onSelect = onSelectService
                )
            }
            Box(modifier = Modifier.weight(1f).fillMaxHeight()) {
                TabletServiceCardItem(
                    service = Service.CLAUDE,
                    snapshot = snapshot,
                    onSelect = onSelectService
                )
            }
        }

        // Row 3: Gemini 2 / Gemini 3
        Row(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Box(modifier = Modifier.weight(1f).fillMaxHeight()) {
                TabletServiceCardItem(
                    service = Service.GEMINI2,
                    snapshot = snapshot,
                    onSelect = onSelectService
                )
            }
            Box(modifier = Modifier.weight(1f).fillMaxHeight()) {
                TabletServiceCardItem(
                    service = Service.GEMINI3,
                    snapshot = snapshot,
                    onSelect = onSelectService
                )
            }
        }
    }
}

@Composable
private fun TabletServiceCardItem(
    service: Service,
    snapshot: UsageSnapshot,
    onSelect: (ServiceUsage) -> Unit,
    modifier: Modifier = Modifier
) {
    val usage = snapshot.services[service] ?: ServiceUsage(
        service = service,
        status = "offline",
        accountDisplay = service.accountTag ?: service.displayName
    )

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
                anchorDate = snapshot.newestFetchedAt ?: Date(),
                usesCreditsScale = usesCredits,
                unit = unit,
                color = CCMBTheme.serviceTint(service)
            )
        }
    }

    TabletAccountCardView(
        usage = usage,
        historyModel = historyModel,
        onSelect = { onSelect(usage) },
        modifier = modifier
    )
}

/**
 * Tablet Utility Card (Flip clock + Weather).
 * Landscape: Four distinct rounded panels (clock 23%, current 15%, hourly 21%, daily 41%)
 * with 8dp gaps, mechanical flip clock with 4 separate digit plates HH:mm, bold white numerals,
 * center horizontal seam, gray hinge marks, date below.
 * Portrait: Fits inside the top-left equal cell in 2x3 grid without hidden scrolling at fontScale 1.15.
 * Top row: 4-digit flip clock (~60%) + current weather (~40%), date below digits.
 * Below: 7 equal hourly columns (~30%) and all 7 daily columns (~32%).
 */
@Composable
fun TabletUtilityCard(
    weatherStore: WeatherStore,
    onRequestWeather: () -> Unit,
    modifier: Modifier = Modifier,
    isLandscape: Boolean = false
) {
    val palette = LocalCCMBPalette.current
    val weatherReading by weatherStore.reading.collectAsState()

    if (isLandscape) {
        LandscapeUtilityContent(
            weatherReading = weatherReading,
            weatherStore = weatherStore,
            onRequestWeather = onRequestWeather,
            modifier = modifier
        )
    } else {
        BoxWithConstraints(
            modifier = modifier
                .clip(RoundedCornerShape(16.dp))
                .background(palette.card)
                .border(1.dp, palette.border, RoundedCornerShape(16.dp))
        ) {
            PortraitCompactUtilityCardContent(
                weatherReading = weatherReading,
                weatherStore = weatherStore,
                onRequestWeather = onRequestWeather
            )
        }
    }
}

/**
 * Landscape center utility:
 * Four separate rounded panels with 8dp gaps:
 * 1. Clock (~23%): Four dark mechanical digit plates HH:mm, white bold numerals, center seam & hinges, date below.
 * 2. Current Weather (~15%): Condition icon, dominant 36sp temp, condition label, high/low, freshness dot + manual refresh.
 * 3. Hourly (~21%): 7 equal columns for next forecasts, horizontal scrollable.
 * 4. Daily (~41%): All 7 rows expanding to fill panel height, readable typography (12-14sp), range bar.
 */
@Composable
private fun LandscapeUtilityContent(
    weatherReading: WeatherReading?,
    weatherStore: WeatherStore,
    onRequestWeather: () -> Unit,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current

    Column(
        modifier = modifier.fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        // 1. Clock Panel (~23% finite available height)
        Box(
            modifier = Modifier
                .weight(0.23f)
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(palette.card)
                .border(1.dp, palette.border, RoundedCornerShape(16.dp)),
            contentAlignment = Alignment.Center
        ) {
            FlipClock(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 8.dp, vertical = 4.dp),
                plateWidth = 50.dp,
                plateHeight = 68.dp,
                fontSize = 38.sp,
                dateFontSize = 12.5.sp
            )
        }

        if (weatherReading != null) {
            // 2. Current Weather Panel (~15% height)
            Box(
                modifier = Modifier
                    .weight(0.15f)
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(palette.card)
                    .border(1.dp, palette.border, RoundedCornerShape(16.dp)),
                contentAlignment = Alignment.Center
            ) {
                LandscapeCurrentWeather(
                    reading = weatherReading,
                    onRefresh = { weatherStore.refresh() },
                    modifier = Modifier.fillMaxSize()
                )
            }

            // 3. Hourly Panel (~21% height)
            Box(
                modifier = Modifier
                    .weight(0.21f)
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(palette.card)
                    .border(1.dp, palette.border, RoundedCornerShape(16.dp))
                    .padding(horizontal = 12.dp, vertical = 8.dp)
            ) {
                LandscapeHourlyContent(
                    reading = weatherReading,
                    modifier = Modifier.fillMaxSize()
                )
            }

            // 4. Daily Panel (~41% height)
            Box(
                modifier = Modifier
                    .weight(0.41f)
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(palette.card)
                    .border(1.dp, palette.border, RoundedCornerShape(16.dp))
                    .padding(horizontal = 12.dp, vertical = 8.dp)
            ) {
                LandscapeDailyContent(
                    reading = weatherReading,
                    modifier = Modifier.fillMaxSize()
                )
            }
        } else {
            // Permission placeholder panel (~77% height)
            Box(
                modifier = Modifier
                    .weight(0.77f)
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(palette.card)
                    .border(1.dp, palette.border, RoundedCornerShape(16.dp)),
                contentAlignment = Alignment.Center
            ) {
                WeatherPermissionPlaceholder(
                    onRequestWeather = onRequestWeather,
                    isCompact = false
                )
            }
        }
    }
}

/**
 * Landscape Current Weather Panel
 */
@Composable
private fun LandscapeCurrentWeather(
    reading: WeatherReading,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current
    val conditionLabel = weatherConditionLabel(reading.symbolName)
    val today = reading.daily.firstOrNull()

    Row(
        modifier = modifier
            .fillMaxSize()
            .padding(horizontal = 14.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            WeatherSymbolIcon(
                symbolName = reading.symbolName,
                tint = weatherSymbolTint(reading.symbolName, palette.accent),
                size = 36.dp
            )
            Spacer(modifier = Modifier.width(10.dp))
            Column {
                Row(verticalAlignment = Alignment.Bottom) {
                    Text(
                        text = "${reading.temperature.roundToInt()}°",
                        fontSize = 36.sp,
                        fontWeight = FontWeight.Bold,
                        fontFamily = FontFamily.Monospace,
                        color = palette.text
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = conditionLabel,
                        fontSize = 13.5.sp,
                        fontWeight = FontWeight.Medium,
                        color = palette.muted,
                        modifier = Modifier.padding(bottom = 3.dp)
                    )
                }
                if (today != null) {
                    Text(
                        text = "최고 ${today.maxTemp.roundToInt()}° · 최저 ${today.minTemp.roundToInt()}°",
                        fontSize = 11.5.sp,
                        color = palette.muted
                    )
                }
            }
        }

        // Freshness / Stale indication with manual refresh tap
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .clip(RoundedCornerShape(6.dp))
                .clickable(onClick = onRefresh)
                .padding(horizontal = 6.dp, vertical = 4.dp)
                .semantics {
                    role = Role.Button
                    contentDescription = "날씨 새로고침"
                }
        ) {
            val dotColor = if (reading.isStale) CCMBTheme.signalRed else Color(0xFF12BD8C)
            Box(
                modifier = Modifier
                    .size(7.dp)
                    .clip(CircleShape)
                    .background(dotColor)
            )
            Spacer(modifier = Modifier.width(4.dp))
            val timeLabel = SimpleDateFormat("HH:mm", Locale.KOREA).format(reading.updatedAt)
            val statusText = if (reading.isStale) "지연 ($timeLabel)" else timeLabel
            Text(
                text = statusText,
                fontSize = 11.sp,
                color = palette.muted
            )
            Spacer(modifier = Modifier.width(3.dp))
            Icon(
                imageVector = Icons.Default.Refresh,
                contentDescription = null,
                tint = palette.muted,
                modifier = Modifier.size(13.dp)
            )
        }
    }
}

/**
 * Landscape Hourly Panel Content
 */
@Composable
private fun LandscapeHourlyContent(
    reading: WeatherReading,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.SpaceBetween
    ) {
        Text(
            text = "시간별 예보",
            fontSize = 11.5.sp,
            fontWeight = FontWeight.SemiBold,
            color = palette.muted
        )
        BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
            val totalW = maxWidth
            val colW = (totalW - 24.dp) / 7
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                reading.hourly.take(12).forEach { hour ->
                    HourlyItem(
                        hour = hour,
                        modifier = Modifier.width(colW),
                        iconSize = 18.dp,
                        timeFontSize = 10.5.sp,
                        fontSize = 12.5.sp,
                        precipFontSize = 9.sp
                    )
                }
            }
        }
    }
}

/**
 * Landscape Daily Panel Content: all 7 rows evenly fill available height.
 */
@Composable
private fun LandscapeDailyContent(
    reading: WeatherReading,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.SpaceBetween
    ) {
        Text(
            text = "7일간 예보",
            fontSize = 11.5.sp,
            fontWeight = FontWeight.SemiBold,
            color = palette.muted
        )
        Column(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
            verticalArrangement = Arrangement.SpaceEvenly
        ) {
            reading.daily.take(7).forEach { day ->
                DailyLandscapeRowItem(
                    day = day,
                    modifier = Modifier.weight(1f)
                )
            }
        }
    }
}

@Composable
private fun DailyLandscapeRowItem(
    day: DailyForecast,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current

    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = day.dayLabel,
            fontSize = 13.sp,
            color = palette.text,
            modifier = Modifier.width(32.dp)
        )
        WeatherSymbolIcon(
            symbolName = day.symbolName,
            tint = weatherSymbolTint(day.symbolName, palette.muted),
            size = 18.dp,
            modifier = Modifier.width(24.dp)
        )
        if (day.precipitationProbability != null && day.precipitationProbability > 0) {
            Text(
                text = "${day.precipitationProbability}%",
                fontSize = 11.sp,
                color = CCMBTheme.codexIconTeal,
                textAlign = TextAlign.End,
                modifier = Modifier.width(30.dp)
            )
        } else {
            Spacer(modifier = Modifier.width(30.dp))
        }
        Spacer(modifier = Modifier.width(6.dp))
        Text(
            text = "${day.minTemp.roundToInt()}°",
            fontSize = 12.5.sp,
            fontFamily = FontFamily.Monospace,
            color = palette.muted,
            textAlign = TextAlign.End,
            modifier = Modifier.width(26.dp)
        )
        Box(
            modifier = Modifier
                .weight(1f)
                .padding(horizontal = 6.dp)
                .height(4.dp)
                .clip(CircleShape)
                .background(palette.border)
        )
        Text(
            text = "${day.maxTemp.roundToInt()}°",
            fontSize = 12.5.sp,
            fontWeight = FontWeight.SemiBold,
            fontFamily = FontFamily.Monospace,
            color = palette.text,
            textAlign = TextAlign.End,
            modifier = Modifier.width(26.dp)
        )
    }
}

/**
 * Compact portrait utility rendering:
 * Top-left cell in 2x3 grid:
 * - Top row (~38%): 4-digit flip clock (~60%) + current weather (~40%), date below digits
 * - Hourly (~30%): 7 equal columns (time, icon, temp, precip)
 * - Weekly (~32%): All 7 daily equal columns (day, icon, stacked high/low, precip)
 * Scaled to fit 792x1080dp at fontScale 1.15 without hidden scrolling;
 * honest scroll fallback for huge a11y fonts.
 */
@Composable
private fun PortraitCompactUtilityCardContent(
    weatherReading: WeatherReading?,
    weatherStore: WeatherStore,
    onRequestWeather: () -> Unit,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current

    BoxWithConstraints(modifier = modifier.fillMaxSize()) {
        val columnHeight = maxHeight
        // Proportional height allocation: top ~38%, hourly ~30%, weekly ~32%
        val paddingV = 16.dp
        val dividersV = 12.dp
        val innerHeight = (columnHeight - paddingV - dividersV).coerceAtLeast(240.dp)
        val topHeight = innerHeight * 0.38f
        val hourlyHeight = innerHeight * 0.30f
        val weeklyHeight = innerHeight * 0.32f

        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 10.dp, vertical = 8.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.SpaceBetween,
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            // 1. Shared top area: 4-digit flip clock (60%) + Current Weather (40%)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(topHeight),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    modifier = Modifier
                        .weight(0.60f)
                        .fillMaxHeight(),
                    contentAlignment = Alignment.Center
                ) {
                    FlipClock(
                        plateWidth = 38.dp,
                        plateHeight = 52.dp,
                        fontSize = 34.sp,
                        dateFontSize = 10.5.sp,
                        spacing = 2.dp
                    )
                }

                Box(
                    modifier = Modifier
                        .padding(horizontal = 4.dp)
                        .width(1.dp)
                        .height(48.dp)
                        .background(palette.border.copy(alpha = 0.5f))
                )

                Box(
                    modifier = Modifier
                        .weight(0.40f)
                        .fillMaxHeight(),
                    contentAlignment = Alignment.Center
                ) {
                    if (weatherReading != null) {
                        CompactCurrentWeather(
                            reading = weatherReading,
                            onRefresh = { weatherStore.refresh() },
                            modifier = Modifier.fillMaxWidth()
                        )
                    } else {
                        WeatherPermissionPlaceholder(
                            onRequestWeather = onRequestWeather,
                            isCompact = true,
                            modifier = Modifier.fillMaxWidth()
                        )
                    }
                }
            }

            // Divider 1
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(0.75.dp)
                    .background(palette.border.copy(alpha = 0.5f))
            )

            // 2. Hourly section: 7 equal columns
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(hourlyHeight),
                verticalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    text = "시간별",
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = palette.muted
                )
                if (weatherReading != null && weatherReading.hourly.isNotEmpty()) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        weatherReading.hourly.take(7).forEach { hour ->
                            HourlyPortraitItem(
                                hour = hour,
                                modifier = Modifier.weight(1f)
                            )
                        }
                    }
                }
            }

            // Divider 2
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(0.75.dp)
                    .background(palette.border.copy(alpha = 0.5f))
            )

            // 3. Weekly section: all 7 equal columns
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(weeklyHeight),
                verticalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    text = "7일간 예보",
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = palette.muted
                )
                if (weatherReading != null && weatherReading.daily.isNotEmpty()) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        weatherReading.daily.take(7).forEach { day ->
                            CompactDailyPortraitColumnItem(
                                day = day,
                                modifier = Modifier.weight(1f)
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * Mechanical Flip Clock:
 * Four individual digit plates for H H : m m (one character per plate),
 * dark vertical gradient, white bold large numerals, center mechanical seam,
 * tiny gray hinge marks, date BELOW clock.
 * Animates only changed digits on minute/hour transitions.
 */
@Composable
private fun FlipClock(
    modifier: Modifier = Modifier,
    plateWidth: Dp = 50.dp,
    plateHeight: Dp = 68.dp,
    fontSize: TextUnit = 38.sp,
    dateFontSize: TextUnit = 12.sp,
    spacing: Dp = 3.dp
) {
    val palette = LocalCCMBPalette.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var currentTime by remember { mutableStateOf(Date()) }

    // Lifecycle aware ticker: ticks device time locally, stops in background (ON_STOP)
    DisposableEffect(lifecycleOwner) {
        var tickerJob: Job? = null
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START) {
                tickerJob = CoroutineScope(Dispatchers.Main).launch {
                    while (isActive) {
                        val now = System.currentTimeMillis()
                        currentTime = Date(now)
                        val delayMs = 1000L - (now % 1000L)
                        delay(delayMs)
                    }
                }
            } else if (event == Lifecycle.Event.ON_STOP) {
                tickerJob?.cancel()
                tickerJob = null
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            tickerJob?.cancel()
            lifecycleOwner.lifecycle.removeObserver(observer)
        }
    }

    val hourStr = remember(currentTime) {
        SimpleDateFormat("HH", Locale.getDefault()).format(currentTime)
    }
    val minuteStr = remember(currentTime) {
        SimpleDateFormat("mm", Locale.getDefault()).format(currentTime)
    }
    val dateStr = remember(currentTime) {
        SimpleDateFormat("M월 d일 EEEE", Locale.KOREA).format(currentTime)
    }

    val h1 = hourStr.getOrElse(0) { '0' }
    val h2 = hourStr.getOrElse(1) { '0' }
    val m1 = minuteStr.getOrElse(0) { '0' }
    val m2 = minuteStr.getOrElse(1) { '0' }

    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center
        ) {
            MechanicalFlipDigit(
                digit = h1,
                isAnimated = true,
                plateWidth = plateWidth,
                plateHeight = plateHeight,
                fontSize = fontSize
            )
            Spacer(modifier = Modifier.width(spacing))
            MechanicalFlipDigit(
                digit = h2,
                isAnimated = true,
                plateWidth = plateWidth,
                plateHeight = plateHeight,
                fontSize = fontSize
            )

            Text(
                text = ":",
                fontSize = fontSize * 0.85f,
                fontWeight = FontWeight.Bold,
                color = Color(0xFFA0A8B8),
                modifier = Modifier.padding(horizontal = 3.dp)
            )

            MechanicalFlipDigit(
                digit = m1,
                isAnimated = true,
                plateWidth = plateWidth,
                plateHeight = plateHeight,
                fontSize = fontSize
            )
            Spacer(modifier = Modifier.width(spacing))
            MechanicalFlipDigit(
                digit = m2,
                isAnimated = true,
                plateWidth = plateWidth,
                plateHeight = plateHeight,
                fontSize = fontSize
            )
        }

        Spacer(modifier = Modifier.height(5.dp))

        Text(
            text = dateStr,
            fontSize = dateFontSize,
            fontWeight = FontWeight.Medium,
            color = palette.muted
        )
    }
}

/**
 * Mechanical Flip Digit Plate:
 * Dark navy/charcoal vertical gradient face, white bold numeral,
 * center horizontal mechanical seam, tiny gray hinge marks on left and right,
 * rounded corners and subtle shadow/border.
 */
@Composable
private fun MechanicalFlipDigit(
    digit: Char,
    isAnimated: Boolean,
    modifier: Modifier = Modifier,
    plateWidth: Dp,
    plateHeight: Dp,
    fontSize: TextUnit
) {
    val text = digit.toString()
    var currentText by remember { mutableStateOf(text) }
    var previousText by remember { mutableStateOf(text) }
    val progress = remember { Animatable(1f) }

    LaunchedEffect(text) {
        if (isAnimated && text != currentText) {
            previousText = currentText
            currentText = text
            progress.snapTo(0f)
            progress.animateTo(
                targetValue = 1f,
                animationSpec = tween(durationMillis = 380, easing = FastOutSlowInEasing)
            )
        } else {
            currentText = text
            previousText = text
        }
    }

    val cornerRadius = 6.dp

    Box(
        modifier = modifier
            .size(width = plateWidth, height = plateHeight)
            .clip(RoundedCornerShape(cornerRadius))
            .background(
                brush = Brush.verticalGradient(
                    colors = listOf(
                        Color(0xFF262A36),
                        Color(0xFF1B1E28),
                        Color(0xFF12141C)
                    )
                )
            )
            .border(0.75.dp, Color(0xFF383F4E), RoundedCornerShape(cornerRadius)),
        contentAlignment = Alignment.Center
    ) {
        val displayedText = if (progress.value < 0.5f) previousText else currentText

        Text(
            text = displayedText,
            fontSize = fontSize,
            fontWeight = FontWeight.Bold,
            fontFamily = FontFamily.Monospace,
            color = Color.White,
            modifier = Modifier.graphicsLayer {
                val rot = if (progress.value < 0.5f) {
                    -progress.value * 180f
                } else {
                    (1f - progress.value) * 180f
                }
                rotationX = rot
                cameraDistance = 12f * density
            }
        )

        // Center horizontal mechanical seam
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(1.dp)
                .background(Color(0xFF090B10))
                .align(Alignment.Center)
        )

        // Tiny gray hinge marks
        Box(
            modifier = Modifier
                .size(width = 3.dp, height = 5.dp)
                .align(Alignment.CenterStart)
                .background(Color(0xFF5A6270), RoundedCornerShape(topEnd = 1.dp, bottomEnd = 1.dp))
        )
        Box(
            modifier = Modifier
                .size(width = 3.dp, height = 5.dp)
                .align(Alignment.CenterEnd)
                .background(Color(0xFF5A6270), RoundedCornerShape(topStart = 1.dp, bottomStart = 1.dp))
        )
    }
}

@Composable
private fun HourlyItem(
    hour: HourlyForecast,
    modifier: Modifier = Modifier,
    iconSize: Dp = 18.dp,
    timeFontSize: TextUnit = 10.sp,
    fontSize: TextUnit = 12.sp,
    precipFontSize: TextUnit = 9.sp
) {
    val palette = LocalCCMBPalette.current

    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp)
    ) {
        Text(
            text = hour.timeLabel,
            fontSize = timeFontSize,
            color = palette.muted,
            maxLines = 1
        )
        WeatherSymbolIcon(
            symbolName = hour.symbolName,
            tint = weatherSymbolTint(hour.symbolName, palette.text),
            size = iconSize
        )
        Text(
            text = "${hour.temperature.roundToInt()}°",
            fontSize = fontSize,
            fontWeight = FontWeight.SemiBold,
            fontFamily = FontFamily.Monospace,
            color = palette.text
        )
        if (hour.precipitationProbability != null && hour.precipitationProbability > 0) {
            Text(
                text = "${hour.precipitationProbability}%",
                fontSize = precipFontSize,
                color = CCMBTheme.codexIconTeal
            )
        } else {
            Spacer(modifier = Modifier.height(12.dp))
        }
    }
}

@Composable
private fun HourlyPortraitItem(
    hour: HourlyForecast,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current

    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(1.dp)
    ) {
        Text(
            text = hour.timeLabel,
            fontSize = 10.sp,
            color = palette.muted,
            maxLines = 1
        )
        WeatherSymbolIcon(
            symbolName = hour.symbolName,
            tint = weatherSymbolTint(hour.symbolName, palette.text),
            size = 16.dp
        )
        Text(
            text = "${hour.temperature.roundToInt()}°",
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            fontFamily = FontFamily.Monospace,
            color = palette.text,
            maxLines = 1
        )
        if (hour.precipitationProbability != null && hour.precipitationProbability > 0) {
            Text(
                text = "${hour.precipitationProbability}%",
                fontSize = 8.5.sp,
                color = CCMBTheme.codexIconTeal,
                maxLines = 1
            )
        } else {
            Spacer(modifier = Modifier.height(10.dp))
        }
    }
}

@Composable
private fun CompactCurrentWeather(
    reading: WeatherReading,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current
    val today = reading.daily.firstOrNull()
    val timeLabel = SimpleDateFormat("HH:mm", Locale.KOREA).format(reading.updatedAt)
    val statusText = if (reading.isStale) "지연 ($timeLabel)" else timeLabel

    Column(
        modifier = modifier
            .clip(RoundedCornerShape(6.dp))
            .clickable(onClick = onRefresh)
            .padding(horizontal = 2.dp, vertical = 2.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center
        ) {
            WeatherSymbolIcon(
                symbolName = reading.symbolName,
                tint = weatherSymbolTint(reading.symbolName, palette.accent),
                size = 24.dp
            )
            Spacer(modifier = Modifier.width(4.dp))
            Text(
                text = "${reading.temperature.roundToInt()}°",
                fontSize = 24.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
                color = palette.text
            )
        }
        Text(
            text = weatherConditionLabel(reading.symbolName),
            fontSize = 11.sp,
            color = palette.muted,
            maxLines = 1
        )
        if (today != null) {
            Text(
                text = "최고 ${today.maxTemp.roundToInt()}° · 최저 ${today.minTemp.roundToInt()}°",
                fontSize = 9.5.sp,
                color = palette.muted,
                maxLines = 1
            )
        }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center
        ) {
            val dotColor = if (reading.isStale) CCMBTheme.signalRed else Color(0xFF12BD8C)
            Box(
                modifier = Modifier
                    .size(5.dp)
                    .clip(CircleShape)
                    .background(dotColor)
            )
            Spacer(modifier = Modifier.width(3.dp))
            Text(
                text = statusText,
                fontSize = 9.sp,
                color = palette.muted,
                maxLines = 1
            )
            Spacer(modifier = Modifier.width(2.dp))
            Icon(
                imageVector = Icons.Default.Refresh,
                contentDescription = "날씨 새로고침",
                tint = palette.muted,
                modifier = Modifier.size(10.dp)
            )
        }
    }
}

@Composable
private fun CompactDailyPortraitColumnItem(
    day: DailyForecast,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current

    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(1.dp)
    ) {
        Text(
            text = day.dayLabel,
            fontSize = 10.sp,
            color = palette.text,
            maxLines = 1
        )
        WeatherSymbolIcon(
            symbolName = day.symbolName,
            tint = weatherSymbolTint(day.symbolName, palette.muted),
            size = 16.dp
        )
        Text(
            text = "${day.maxTemp.roundToInt()}°",
            fontSize = 10.5.sp,
            fontWeight = FontWeight.SemiBold,
            fontFamily = FontFamily.Monospace,
            color = palette.text,
            maxLines = 1
        )
        Text(
            text = "${day.minTemp.roundToInt()}°",
            fontSize = 10.sp,
            fontFamily = FontFamily.Monospace,
            color = palette.muted,
            maxLines = 1
        )
        if (day.precipitationProbability != null && day.precipitationProbability > 0) {
            Text(
                text = "${day.precipitationProbability}%",
                fontSize = 8.5.sp,
                color = CCMBTheme.codexIconTeal,
                maxLines = 1
            )
        } else {
            Spacer(modifier = Modifier.height(10.dp))
        }
    }
}

@Composable
private fun WeatherPermissionPlaceholder(
    onRequestWeather: () -> Unit,
    modifier: Modifier = Modifier,
    isCompact: Boolean = false
) {
    val palette = LocalCCMBPalette.current

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = if (isCompact) 2.dp else 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        WeatherSymbolIcon(
            symbolName = "cloud_sun",
            tint = weatherSymbolTint("cloud_sun", palette.muted),
            size = if (isCompact) 20.dp else 28.dp
        )
        Spacer(modifier = Modifier.height(if (isCompact) 2.dp else 6.dp))
        Text(
            text = "날씨 정보 보기",
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            color = palette.accent,
            modifier = Modifier
                .clip(RoundedCornerShape(8.dp))
                .clickable(onClick = onRequestWeather)
                .padding(horizontal = 12.dp, vertical = 6.dp)
        )
        Text(
            text = "위치 권한을 허용하면 현재, 시간별, 7일 예보가 표시됩니다",
            fontSize = 10.sp,
            color = palette.muted,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 8.dp)
        )
    }
}

private fun weatherSymbolTint(symbolName: String, defaultColor: Color): Color = when (symbolName) {
    "sun", "cloud_sun" -> Color(0xFFFFB020)
    "rain", "drizzle", "thunder" -> Color(0xFF4DA3FF)
    "snow" -> Color(0xFF80D8FF)
    else -> defaultColor
}

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
