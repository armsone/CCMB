package com.armsone.ccmb.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.armsone.ccmb.format.CCMBFormat
import com.armsone.ccmb.model.Account24hModel
import com.armsone.ccmb.model.Service
import com.armsone.ccmb.model.ServiceUsage
import com.armsone.ccmb.theme.CCMBTheme
import com.armsone.ccmb.theme.LocalCCMBPalette

/**
 * 쿼터 컬럼 한 줄의 높이를 폰트 메트릭과 무관하게 고정한다.
 * 한글 폴백 폰트(Noto Sans CJK)는 자연 줄 높이가 약 1.45em이라 11sp+24sp+9.5sp 세 줄이
 * 56dp 행을 넘쳐 날짜가 바 뒤로 잘리므로, Trim.None 으로 줄 높이를 명시해 합계를 52dp로 맞춘다.
 */
private fun quotaLineStyle(lineHeight: TextUnit): TextStyle = TextStyle(
    lineHeight = lineHeight,
    lineHeightStyle = LineHeightStyle(
        alignment = LineHeightStyle.Alignment.Center,
        trim = LineHeightStyle.Trim.None
    ),
    platformStyle = PlatformTextStyle(includeFontPadding = false)
)

private val QuotaLabelStyle = quotaLineStyle(14.sp)   // 11sp 라벨
private val QuotaNumberStyle = quotaLineStyle(26.sp)  // 24sp 퍼센트
private val QuotaTokenStyle = quotaLineStyle(20.sp)   // 16sp 토큰 잔액
private val QuotaDateStyle = quotaLineStyle(12.sp)    // 9.5sp 리셋 시각
private val QuotaExpiryStyle = quotaLineStyle(11.sp)  // 8.5sp 리셋권 만료(최대 2줄)

/**
 * 상단 행 66dp = 지표 행 56dp + 간격 2dp + 바 7dp (+1dp 여유).
 * 지표 행 56dp는 고정 줄 높이 14+26+12 = 52dp 를 담고, 리셋권 컬럼은 라벨 14 + 만료 박스 38 = 52dp.
 * 이전 80/60/42 는 바 아래 11dp 가 비어 그래프 행이 18dp 로 납작해졌다. 폰트 배율이 커지면 비례해 늘린다.
 */
private const val HEADER_ROW_DP = 66f
private const val METRICS_ROW_DP = 56f
private const val EXPIRY_BOX_DP = 38f

/** cardHeight 가 없을 때(큰 글꼴 배율) 그래프가 글자 높이로 접히지 않도록 주는 고정 플롯 높이. */
private const val PLOT_FALLBACK_DP = 72f

@Composable
fun AccountCardView(
    usage: ServiceUsage,
    historyModel: Account24hModel?,
    cardHeight: Dp?,
    onSelect: () -> Unit,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current
    val service = usage.service
    val accent = CCMBTheme.serviceTint(service)
    val fontScale = LocalDensity.current.fontScale.coerceAtLeast(1f)

    val a11ySummary = buildString {
        append(service.displayName)
        usage.accountDisplay?.let { append(", 계정 $it") }
        if (service == Service.CODEX) {
            usage.weeklyWindow?.remainingPercent?.let { append(", 주간 남음 ${CCMBFormat.percent(it)}") }
            usage.creditBalance?.let { append(", 토큰 ${CCMBFormat.groupedInteger(it)}") }
            usage.codexResetCreditsAvailable?.let { append(", 리셋권 ${it}개") }
        } else if (service == Service.CLAUDE) {
            usage.fableWeeklyWindow?.remainingPercent?.let { append(", 페이블 주간 남음 ${CCMBFormat.percent(it)}") }
            usage.fiveHourWindow?.remainingPercent?.let { append(", 세션 남음 ${CCMBFormat.percent(it)}") }
            usage.weeklyWindow?.remainingPercent?.let { append(", 주간 남음 ${CCMBFormat.percent(it)}") }
        } else {
            usage.fiveHourWindow?.remainingPercent?.let { append(", 세션 남음 ${CCMBFormat.percent(it)}") }
            usage.weeklyWindow?.remainingPercent?.let { append(", 주간 남음 ${CCMBFormat.percent(it)}") }
        }
    }

    var isFocused by remember { mutableStateOf(false) }

    val cardBrush = Brush.verticalGradient(
        colors = listOf(
            if (isFocused) palette.surface2 else palette.card,
            if (isFocused) palette.surface else palette.surface
        )
    )

    Box(
        modifier = modifier
            .fillMaxWidth()
            .then(if (cardHeight != null) Modifier.height(cardHeight) else Modifier)
            .clip(RoundedCornerShape(16.dp))
            .background(cardBrush)
            .border(
                width = if (isFocused) 2.dp else 1.dp,
                color = if (isFocused) palette.accent else palette.border,
                shape = RoundedCornerShape(16.dp)
            )
            .onFocusChanged { isFocused = it.isFocused }
            .focusable()
            .clickable(onClick = onSelect)
            .padding(horizontal = 14.dp, vertical = 10.dp)
            .semantics { contentDescription = a11ySummary }
    ) {
        Column(
            modifier = Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.SpaceBetween
        ) {
            // Upper row: Service identity (left) + 232dp locked quota block (right)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .height((HEADER_ROW_DP * fontScale).dp),
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                // Identity left
                Row(
                    modifier = Modifier.weight(1f, fill = false),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    AccountIconView(service = service, accent = accent, size = 36.dp)
                    Spacer(modifier = Modifier.width(10.dp))
                    Column {
                        Text(
                            text = service.displayName,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Bold,
                            color = palette.text,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        val accountId = CCMBFormat.accountID(usage) ?: service.accountTag
                        if (accountId != null) {
                            Text(
                                text = accountId,
                                fontSize = 11.5.sp,
                                color = palette.muted,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                }

                // Locked quota block (width 232dp)
                LockedQuotaBlock(
                    usage = usage,
                    accent = accent
                )
            }

            Spacer(modifier = Modifier.height(4.dp))

            // 24h consumption plot. cardHeight 가 있으면 남은 높이를 모두 채우고(fill=true),
            // 없으면 Account24hPlot 내부 Row 가 글자 높이로 접히므로 고정 높이를 넘긴다.
            Account24hPlot(
                model = historyModel,
                placeholder = "NAS가 기록을 모으는 중입니다",
                fixedHeight = if (cardHeight == null) (PLOT_FALLBACK_DP * fontScale).dp else null,
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f, fill = cardHeight != null)
            )
        }
    }
}

@Composable
fun LockedQuotaBlock(
    usage: ServiceUsage,
    accent: Color,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current
    val service = usage.service
    val lockedWidth = 232.dp
    val colWidth = 76.67.dp
    val fontScale = LocalDensity.current.fontScale.coerceAtLeast(1f)

    Column(
        modifier = modifier.width(lockedWidth),
        horizontalAlignment = Alignment.End
    ) {
        // 3-columns row (height 56dp at default font scale; lines total 14+26+12 = 52dp)
        Row(
            modifier = Modifier
                .width(lockedWidth)
                .height((METRICS_ROW_DP * fontScale).dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.End
        ) {
            // Column 1
            Box(
                modifier = Modifier
                    .width(colWidth)
                    .fillMaxHeight(),
                contentAlignment = Alignment.Center
            ) {
                when (service) {
                    Service.CODEX -> CodexResetCreditColumn(usage, accent)
                    Service.CLAUDE -> ClaudeFableColumn(usage)
                    else -> {
                        // Gemini: Empty column (Color.clear)
                        Box(modifier = Modifier.fillMaxSize())
                    }
                }
            }

            // Divider 1 (between Col 1 and Col 2)
            // Gemini hides this divider (opacity 0)
            val showFirstDivider = !service.isGemini
            Box(
                modifier = Modifier
                    .width(1.dp)
                    .height(42.dp)
                    .background(if (showFirstDivider) palette.border else Color.Transparent)
            )

            // Column 2
            Box(
                modifier = Modifier
                    .width(colWidth)
                    .fillMaxHeight(),
                contentAlignment = Alignment.Center
            ) {
                when (service) {
                    Service.CODEX -> CodexWeeklyColumn(usage, accent)
                    Service.CLAUDE -> ClaudeSessionColumn(usage)
                    else -> GeminiSessionColumn(usage, accent)
                }
            }

            // Divider 2 (between Col 2 and Col 3) - always visible
            Box(
                modifier = Modifier
                    .width(1.dp)
                    .height(42.dp)
                    .background(palette.border)
            )

            // Column 3
            Box(
                modifier = Modifier
                    .width(colWidth)
                    .fillMaxHeight(),
                contentAlignment = Alignment.Center
            ) {
                when (service) {
                    Service.CODEX -> CodexTokenColumn(usage)
                    Service.CLAUDE -> ClaudeWeeklyColumn(usage)
                    else -> GeminiWeeklyColumn(usage, accent)
                }
            }
        }

        Spacer(modifier = Modifier.height(2.dp))

        // 7dp Mini Quota Bar (width 176dp, aligned to the right inside the 232dp block)
        val remainingForBar = when (service) {
            Service.CODEX -> usage.weeklyWindow?.remainingPercent
            Service.CLAUDE -> usage.fiveHourWindow?.remainingPercent
            else -> usage.fiveHourWindow?.remainingPercent
        }
        val barTint = if (service == Service.CLAUDE) CCMBTheme.claudeCoral else accent

        DashQuotaBar(
            remaining = remainingForBar,
            tint = barTint,
            height = 7.dp,
            modifier = Modifier.width(176.dp)
        )
    }
}

// MARK: - Column Components

@Composable
internal fun CodexResetCreditColumn(usage: ServiceUsage, accent: Color) {
    val palette = LocalCCMBPalette.current
    val count = usage.codexResetCreditsAvailable
    val expirations = usage.codexResetCreditExpirations
    val fontScale = LocalDensity.current.fontScale.coerceAtLeast(1f)

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(
            text = if (count != null) "리셋권 ${count}개" else "리셋권",
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            color = palette.muted,
            style = QuotaLabelStyle
        )
        Box(
            modifier = Modifier
                .height((EXPIRY_BOX_DP * fontScale).dp)
                .fillMaxWidth(),
            contentAlignment = Alignment.Center
        ) {
            if (expirations.isNotEmpty()) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    expirations.take(2).forEach { date ->
                        Text(
                            text = CCMBFormat.quotaTime(date),
                            fontSize = 8.5.sp,
                            fontFamily = FontFamily.Monospace,
                            color = palette.text2,
                            maxLines = 1,
                            style = QuotaExpiryStyle
                        )
                    }
                }
            } else {
                Text(
                    text = if (count == 0) "없음" else "만료정보없음",
                    fontSize = 8.5.sp,
                    color = palette.muted,
                    style = QuotaExpiryStyle
                )
            }
        }
    }
}

@Composable
internal fun CodexWeeklyColumn(usage: ServiceUsage, accent: Color) {
    val palette = LocalCCMBPalette.current
    val weekly = usage.weeklyWindow
    val percentVal = weekly?.remainingPercent
    val percentColor = if (percentVal != null && percentVal < CCMBTheme.lowRemainingThreshold) {
        palette.danger
    } else {
        accent
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(
            text = "주간",
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            color = palette.muted,
            style = QuotaLabelStyle
        )
        Text(
            text = percentVal?.let { "${it.toInt()}%" } ?: "—",
            fontSize = 24.sp,
            fontWeight = FontWeight.Bold,
            color = percentColor,
            style = QuotaNumberStyle
        )
        Text(
            text = weekly?.resetsAt?.let { CCMBFormat.quotaTime(it) } ?: "—",
            fontSize = 9.5.sp,
            color = palette.muted,
            maxLines = 1,
            style = QuotaDateStyle
        )
    }
}

@Composable
internal fun CodexTokenColumn(usage: ServiceUsage) {
    val palette = LocalCCMBPalette.current
    val balance = usage.creditBalance
    val unlimited = usage.creditUnlimited

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(
            text = "토큰",
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            color = palette.muted,
            style = QuotaLabelStyle
        )
        Text(
            text = when {
                unlimited -> "무제한"
                balance != null -> CCMBFormat.groupedInteger(balance)
                else -> "—"
            },
            fontSize = 16.sp,
            fontWeight = FontWeight.Bold,
            color = palette.text,
            maxLines = 1,
            style = QuotaTokenStyle
        )
        Spacer(modifier = Modifier.height(with(LocalDensity.current) { 12.sp.toDp() }))
    }
}

@Composable
internal fun ClaudeFableColumn(usage: ServiceUsage) {
    val palette = LocalCCMBPalette.current
    val fable = usage.fableWeeklyWindow
    val percentVal = fable?.remainingPercent
    val percentColor = if (percentVal != null && percentVal < CCMBTheme.lowRemainingThreshold) {
        palette.danger
    } else {
        CCMBTheme.claudeFable
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(
            text = "페이블",
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            color = palette.muted,
            style = QuotaLabelStyle
        )
        Text(
            text = percentVal?.let { "${it.toInt()}%" } ?: "—",
            fontSize = 24.sp,
            fontWeight = FontWeight.Bold,
            color = percentColor,
            style = QuotaNumberStyle
        )
        Text(
            text = fable?.resetsAt?.let { CCMBFormat.quotaTime(it) } ?: "—",
            fontSize = 9.5.sp,
            color = palette.muted,
            maxLines = 1,
            style = QuotaDateStyle
        )
    }
}

@Composable
internal fun ClaudeSessionColumn(usage: ServiceUsage) {
    val palette = LocalCCMBPalette.current
    val session = usage.fiveHourWindow
    val percentVal = session?.remainingPercent
    val percentColor = if (percentVal != null && percentVal < CCMBTheme.lowRemainingThreshold) {
        palette.danger
    } else {
        CCMBTheme.claudeCoral
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(
            text = "세션",
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            color = palette.muted,
            style = QuotaLabelStyle
        )
        Text(
            text = percentVal?.let { "${it.toInt()}%" } ?: "—",
            fontSize = 24.sp,
            fontWeight = FontWeight.Bold,
            color = percentColor,
            style = QuotaNumberStyle
        )
        Text(
            text = session?.resetsAt?.let { CCMBFormat.quotaTime(it) } ?: "—",
            fontSize = 9.5.sp,
            color = palette.muted,
            maxLines = 1,
            style = QuotaDateStyle
        )
    }
}

@Composable
internal fun ClaudeWeeklyColumn(usage: ServiceUsage) {
    val palette = LocalCCMBPalette.current
    val weekly = usage.weeklyWindow
    val percentVal = weekly?.remainingPercent
    val percentColor = if (percentVal != null && percentVal < CCMBTheme.lowRemainingThreshold) {
        palette.danger
    } else {
        CCMBTheme.claudeCoral
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(
            text = "주간",
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            color = palette.muted,
            style = QuotaLabelStyle
        )
        Text(
            text = percentVal?.let { "${it.toInt()}%" } ?: "—",
            fontSize = 24.sp,
            fontWeight = FontWeight.Bold,
            color = percentColor,
            style = QuotaNumberStyle
        )
        Text(
            text = weekly?.resetsAt?.let { CCMBFormat.quotaTime(it) } ?: "—",
            fontSize = 9.5.sp,
            color = palette.muted,
            maxLines = 1,
            style = QuotaDateStyle
        )
    }
}

@Composable
internal fun GeminiSessionColumn(usage: ServiceUsage, accent: Color) {
    val palette = LocalCCMBPalette.current
    val session = usage.fiveHourWindow
    val percentVal = session?.remainingPercent
    val percentColor = if (percentVal != null && percentVal < CCMBTheme.lowRemainingThreshold) {
        palette.danger
    } else {
        accent
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(
            text = "세션",
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            color = palette.muted,
            style = QuotaLabelStyle
        )
        Text(
            text = percentVal?.let { "${it.toInt()}%" } ?: "—",
            fontSize = 24.sp,
            fontWeight = FontWeight.Bold,
            color = percentColor,
            style = QuotaNumberStyle
        )
        Text(
            text = session?.resetsAt?.let { CCMBFormat.quotaTime(it) } ?: "—",
            fontSize = 9.5.sp,
            color = palette.muted,
            maxLines = 1,
            style = QuotaDateStyle
        )
    }
}

@Composable
internal fun GeminiWeeklyColumn(usage: ServiceUsage, accent: Color) {
    val palette = LocalCCMBPalette.current
    val weekly = usage.weeklyWindow
    val percentVal = weekly?.remainingPercent
    val percentColor = if (percentVal != null && percentVal < CCMBTheme.lowRemainingThreshold) {
        palette.danger
    } else {
        accent
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(
            text = "주간",
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            color = palette.muted,
            style = QuotaLabelStyle
        )
        Text(
            text = percentVal?.let { "${it.toInt()}%" } ?: "—",
            fontSize = 24.sp,
            fontWeight = FontWeight.Bold,
            color = percentColor,
            style = QuotaNumberStyle
        )
        Text(
            text = weekly?.resetsAt?.let { CCMBFormat.quotaTime(it) } ?: "—",
            fontSize = 9.5.sp,
            color = palette.muted,
            maxLines = 1,
            style = QuotaDateStyle
        )
    }
}

@Composable
fun TabletQuotaBlock(
    usage: ServiceUsage,
    accent: Color,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current
    val service = usage.service
    val fontScale = LocalDensity.current.fontScale.coerceAtLeast(1f)

    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height((METRICS_ROW_DP * fontScale).dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceEvenly
        ) {
            // Column 1
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight(),
                contentAlignment = Alignment.Center
            ) {
                when (service) {
                    Service.CODEX -> CodexResetCreditColumn(usage, accent)
                    Service.CLAUDE -> ClaudeFableColumn(usage)
                    else -> Box(modifier = Modifier.fillMaxSize())
                }
            }

            // Divider 1
            val showFirstDivider = !service.isGemini
            Box(
                modifier = Modifier
                    .width(1.dp)
                    .height(42.dp)
                    .background(if (showFirstDivider) palette.border else Color.Transparent)
            )

            // Column 2
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight(),
                contentAlignment = Alignment.Center
            ) {
                when (service) {
                    Service.CODEX -> CodexWeeklyColumn(usage, accent)
                    Service.CLAUDE -> ClaudeSessionColumn(usage)
                    else -> GeminiSessionColumn(usage, accent)
                }
            }

            // Divider 2
            Box(
                modifier = Modifier
                    .width(1.dp)
                    .height(42.dp)
                    .background(palette.border)
            )

            // Column 3
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight(),
                contentAlignment = Alignment.Center
            ) {
                when (service) {
                    Service.CODEX -> CodexTokenColumn(usage)
                    Service.CLAUDE -> ClaudeWeeklyColumn(usage)
                    else -> GeminiWeeklyColumn(usage, accent)
                }
            }
        }

        Spacer(modifier = Modifier.height(2.dp))

        // Mini Quota Bar (aligned to right 2 columns)
        val remainingForBar = when (service) {
            Service.CODEX -> usage.weeklyWindow?.remainingPercent
            Service.CLAUDE -> usage.fiveHourWindow?.remainingPercent
            else -> usage.fiveHourWindow?.remainingPercent
        }
        val barTint = if (service == Service.CLAUDE) CCMBTheme.claudeCoral else accent

        Box(
            modifier = Modifier.fillMaxWidth(),
            contentAlignment = Alignment.CenterEnd
        ) {
            DashQuotaBar(
                remaining = remainingForBar,
                tint = barTint,
                height = 6.dp,
                modifier = Modifier.fillMaxWidth(0.67f)
            )
        }
    }
}

@Composable
fun TabletAccountCardView(
    usage: ServiceUsage,
    historyModel: Account24hModel?,
    onSelect: () -> Unit,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current
    val service = usage.service
    val accent = CCMBTheme.serviceTint(service)

    val a11ySummary = buildString {
        append(service.displayName)
        usage.accountDisplay?.let { append(", 계정 $it") }
        if (service == Service.CODEX) {
            usage.weeklyWindow?.remainingPercent?.let { append(", 주간 남음 ${CCMBFormat.percent(it)}") }
            usage.creditBalance?.let { append(", 토큰 ${CCMBFormat.groupedInteger(it)}") }
            usage.codexResetCreditsAvailable?.let { append(", 리셋권 ${it}개") }
        } else if (service == Service.CLAUDE) {
            usage.fableWeeklyWindow?.remainingPercent?.let { append(", 페이블 주간 남음 ${CCMBFormat.percent(it)}") }
            usage.fiveHourWindow?.remainingPercent?.let { append(", 세션 남음 ${CCMBFormat.percent(it)}") }
            usage.weeklyWindow?.remainingPercent?.let { append(", 주간 남음 ${CCMBFormat.percent(it)}") }
        } else {
            usage.fiveHourWindow?.remainingPercent?.let { append(", 세션 남음 ${CCMBFormat.percent(it)}") }
            usage.weeklyWindow?.remainingPercent?.let { append(", 주간 남음 ${CCMBFormat.percent(it)}") }
        }
    }

    var isFocused by remember { mutableStateOf(false) }

    val cardBrush = Brush.verticalGradient(
        colors = listOf(
            if (isFocused) palette.surface2 else palette.card,
            if (isFocused) palette.surface else palette.surface
        )
    )

    Box(
        modifier = modifier
            .fillMaxSize()
            .clip(RoundedCornerShape(16.dp))
            .background(cardBrush)
            .border(
                width = if (isFocused) 2.dp else 1.dp,
                color = if (isFocused) palette.accent else palette.border,
                shape = RoundedCornerShape(16.dp)
            )
            .onFocusChanged { isFocused = it.isFocused }
            .focusable()
            .clickable(onClick = onSelect)
            .padding(horizontal = 12.dp, vertical = 8.dp)
            .semantics { contentDescription = a11ySummary }
    ) {
        Column(
            modifier = Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.SpaceBetween
        ) {
            // 1. Identity Row
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(34.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                AccountIconView(service = service, accent = accent, size = 30.dp)
                Spacer(modifier = Modifier.width(8.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = service.displayName,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Bold,
                        color = palette.text,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    val accountId = CCMBFormat.accountID(usage) ?: service.accountTag
                    if (accountId != null) {
                        Text(
                            text = accountId,
                            fontSize = 10.5.sp,
                            color = palette.muted,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(2.dp))

            // 2. Metrics (Identity then Metrics then Chart)
            TabletQuotaBlock(
                usage = usage,
                accent = accent,
                modifier = Modifier.fillMaxWidth()
            )

            Spacer(modifier = Modifier.height(2.dp))

            // 3. 24h consumption plot
            Account24hPlot(
                model = historyModel,
                placeholder = "NAS가 기록을 모으는 중입니다",
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
            )
        }
    }
}
