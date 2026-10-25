package com.armsone.ccmb.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.armsone.ccmb.R
import com.armsone.ccmb.model.Service
import com.armsone.ccmb.store.SnapshotStore
import com.armsone.ccmb.theme.CCMBAppearance
import com.armsone.ccmb.theme.CCMBTheme
import com.armsone.ccmb.theme.LocalCCMBPalette
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

@Composable
fun AccountIconView(
    service: Service,
    accent: Color,
    size: Dp = 36.dp,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current
    val cornerRadius = size * 0.26f
    val isGemini = service.isGemini

    val bgColor = if (isGemini) {
        Color.White
    } else if (service == Service.CODEX) {
        if (palette.isDark) palette.surface2 else CCMBTheme.codexIconDark
    } else {
        accent
    }

    Box(
        modifier = modifier
            .size(size)
            .clip(RoundedCornerShape(cornerRadius))
            .background(bgColor)
            .then(
                if (isGemini) Modifier.border(1.5.dp, accent, RoundedCornerShape(cornerRadius))
                else Modifier
            ),
        contentAlignment = Alignment.Center
    ) {
        when (service) {
            Service.CODEX -> {
                Canvas(modifier = Modifier.fillMaxSize()) {
                    val w = this.size.width
                    val h = this.size.height
                    val teal = CCMBTheme.codexIconTeal
                    val stroke = Stroke(
                        width = w * 0.085f,
                        cap = StrokeCap.Round,
                        join = StrokeJoin.Round
                    )

                    // Chevron `>`
                    val chevron = Path().apply {
                        moveTo(w * 0.25f, h * 0.33f)
                        lineTo(w * 0.46f, h * 0.50f)
                        lineTo(w * 0.25f, h * 0.67f)
                    }
                    drawPath(chevron, teal, style = stroke)

                    // Underscore `_`
                    val underscore = Path().apply {
                        moveTo(w * 0.54f, h * 0.68f)
                        lineTo(w * 0.76f, h * 0.68f)
                    }
                    drawPath(underscore, teal, style = stroke)
                }
            }
            Service.CLAUDE -> {
                Canvas(modifier = Modifier.fillMaxSize()) {
                    val center = Offset(this.size.width / 2f, this.size.height / 2f)
                    val unit = this.size.width
                    val rays = 12
                    val stroke = Stroke(width = unit * 0.05f, cap = StrokeCap.Round)

                    for (i in 0 until rays) {
                        val angle = (i.toDouble() / rays) * 2 * Math.PI
                        val outer = (if (i % 2 == 0) 0.31 else 0.25) * unit
                        val inner = 0.08 * unit

                        val start = Offset(
                            (center.x + cos(angle) * inner).toFloat(),
                            (center.y + sin(angle) * inner).toFloat()
                        )
                        val end = Offset(
                            (center.x + cos(angle) * outer).toFloat(),
                            (center.y + sin(angle) * outer).toFloat()
                        )
                        drawLine(Color.White, start, end, strokeWidth = stroke.width, cap = stroke.cap)
                    }
                }
            }
            else -> {
                // Gemini: all accounts use existing byte-identical iPhone GeminiLogo.png full fitted glyph with white rounded background and 1.5dp account border; no recolored star
                Image(
                    painter = painterResource(id = R.drawable.gemini_logo),
                    contentDescription = null,
                    modifier = Modifier.fillMaxSize(),
                    contentScale = ContentScale.Fit
                )
            }
        }
    }
}

@Composable
fun DashQuotaBar(
    remaining: Double?,
    tint: Color,
    height: Dp = 7.dp,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current

    Box(
        modifier = modifier
            .height(height)
            .clip(CircleShape)
            .background(palette.surface2)
    ) {
        if (remaining != null) {
            val fraction = min(100.0, max(0.0, remaining)) / 100.0
            if (fraction > 0) {
                Box(
                    modifier = Modifier
                        .fillMaxSize(fraction.toFloat())
                        .clip(CircleShape)
                        .background(tint)
                )
            }
        }
    }
}

@Composable
fun CCMBThemeIcon(
    appearance: CCMBAppearance,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current
    val accentColor = palette.accent

    Canvas(modifier = modifier.size(24.dp)) {
        val s = min(size.width, size.height) / 24f
        val originX = (size.width - 24f * s) / 2f
        val originY = (size.height - 24f * s) / 2f

        fun p(x: Float, y: Float) = Offset(originX + x * s, originY + y * s)

        val stroke = Stroke(width = 1.7f * s, cap = StrokeCap.Round, join = StrokeJoin.Round)
        val thin = Stroke(width = 1.4f * s, cap = StrokeCap.Round, join = StrokeJoin.Round)

        when (appearance) {
            CCMBAppearance.LIGHT -> {
                // Sun circle + 8 rays
                drawCircle(
                    color = accentColor,
                    radius = 3.8f * s,
                    center = p(12f, 12f),
                    style = stroke
                )
                val rayCoords = listOf(
                    listOf(12f, 3.5f, 12f, 5.7f), listOf(12f, 18.3f, 12f, 20.5f),
                    listOf(3.5f, 12f, 5.7f, 12f), listOf(18.3f, 12f, 20.5f, 12f),
                    listOf(6f, 6f, 7.6f, 7.6f), listOf(16.4f, 16.4f, 18f, 18f),
                    listOf(6f, 18f, 7.6f, 16.4f), listOf(16.4f, 7.6f, 18f, 6f)
                )
                for (r in rayCoords) {
                    drawLine(accentColor, p(r[0], r[1]), p(r[2], r[3]), strokeWidth = stroke.width, cap = stroke.cap)
                }
            }
            CCMBAppearance.FRIDAY -> {
                // Hexagon + center filled dot + 4 cardinal cross ticks
                val hexPath = Path().apply {
                    val pts = listOf(
                        Pair(12f, 3f), Pair(19.8f, 7.5f), Pair(19.8f, 16.5f),
                        Pair(12f, 21f), Pair(4.2f, 16.5f), Pair(4.2f, 7.5f)
                    )
                    moveTo(p(pts[0].first, pts[0].second).x, p(pts[0].first, pts[0].second).y)
                    for (i in 1 until pts.size) {
                        lineTo(p(pts[i].first, pts[i].second).x, p(pts[i].first, pts[i].second).y)
                    }
                    close()
                }
                drawPath(hexPath, accentColor, style = stroke)
                drawCircle(accentColor, radius = 3f * s, center = p(12f, 12f))
                val ticks = listOf(
                    listOf(12f, 9f, 12f, 6.5f), listOf(12f, 17.5f, 12f, 15f),
                    listOf(9f, 12f, 6.5f, 12f), listOf(17.5f, 12f, 15f, 12f)
                )
                for (t in ticks) {
                    drawLine(accentColor, p(t[0], t[1]), p(t[2], t[3]), strokeWidth = thin.width, cap = thin.cap)
                }
            }
            CCMBAppearance.JARVIS -> {
                // Arc reactor: dashed outer ring, inner circle, small center core
                drawCircle(
                    color = accentColor,
                    radius = 9f * s,
                    center = p(12f, 12f),
                    style = Stroke(
                        width = 1.7f * s,
                        cap = StrokeCap.Round,
                        pathEffect = PathEffect.dashPathEffect(floatArrayOf(15.4f * s, 3.45f * s), 0f)
                    )
                )
                drawCircle(accentColor, radius = 5f * s, center = p(12f, 12f), style = thin)
                drawCircle(accentColor, radius = 1.7f * s, center = p(12f, 12f))
            }
            CCMBAppearance.ULTRON -> {
                // Visor polygon helmet + eyes
                val visorPath = Path().apply {
                    val pts = listOf(
                        Pair(6f, 4f), Pair(18f, 4f), Pair(20.5f, 9f), Pair(20.5f, 15f),
                        Pair(16.5f, 20f), Pair(7.5f, 20f), Pair(3.5f, 15f), Pair(3.5f, 9f)
                    )
                    moveTo(p(pts[0].first, pts[0].second).x, p(pts[0].first, pts[0].second).y)
                    for (i in 1 until pts.size) {
                        lineTo(p(pts[i].first, pts[i].second).x, p(pts[i].first, pts[i].second).y)
                    }
                    close()
                }
                drawPath(visorPath, accentColor, style = stroke)

                val leftEye = Path().apply {
                    val pts = listOf(Pair(7.4f, 10.4f), Pair(11f, 11.7f), Pair(10.7f, 13.1f), Pair(7.4f, 12.2f))
                    moveTo(p(pts[0].first, pts[0].second).x, p(pts[0].first, pts[0].second).y)
                    for (i in 1 until pts.size) lineTo(p(pts[i].first, pts[i].second).x, p(pts[i].first, pts[i].second).y)
                    close()
                }
                drawPath(leftEye, accentColor)

                val rightEye = Path().apply {
                    val pts = listOf(Pair(16.6f, 10.4f), Pair(13f, 11.7f), Pair(13.3f, 13.1f), Pair(16.6f, 12.2f))
                    moveTo(p(pts[0].first, pts[0].second).x, p(pts[0].first, pts[0].second).y)
                    for (i in 1 until pts.size) lineTo(p(pts[i].first, pts[i].second).x, p(pts[i].first, pts[i].second).y)
                    close()
                }
                drawPath(rightEye, accentColor)

                drawLine(accentColor, p(9.5f, 16.5f), p(14.5f, 16.5f), strokeWidth = thin.width, cap = thin.cap)
            }
        }
    }
}

/**
 * 헤더의 수동 새로 고침 버튼.
 * - nasConnecting: 지금 이 앱이 NAS 요청을 보내 처리 중 → 스피너 + 비활성(중복 요청 방지).
 * - nasRefreshBusy: NAS 쪽 수집이 아직 도는 중(STILL_RUNNING 응답) → 스피너는 유지하되
 *   다시 탭해 재확인할 수 있게 활성 상태로 둔다.
 * 타이머 캐시(nextAutomaticRefreshAt)로 계산한 "N초 뒤" 같은 문구는 컴포지션 시점에 한 번 굳어
 * 실제와 어긋나므로 쓰지 않는다. 실제 Store 상태만 표시한다.
 */
@Composable
fun CompactRefreshControl(
    store: SnapshotStore,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current
    val nasConnecting by store.nasConnecting.collectAsState()
    val nasRefreshBusy by store.nasRefreshBusy.collectAsState()
    val showSpinner = nasConnecting || nasRefreshBusy
    val description = when {
        nasConnecting -> "새로 고침 처리 중"
        nasRefreshBusy -> "NAS 수집 중. 탭하면 다시 확인"
        else -> "지금 새로 고침"
    }

    IconButton(
        onClick = { store.refresh(isAutomatic = false) },
        enabled = !nasConnecting,
        modifier = modifier
            .size(width = 44.dp, height = 36.dp)
            .semantics { contentDescription = description }
    ) {
        if (showSpinner) {
            CircularProgressIndicator(
                modifier = Modifier.size(18.dp),
                color = palette.accent,
                strokeWidth = 2.dp
            )
        } else {
            Icon(
                imageVector = Icons.Default.Refresh,
                contentDescription = null,
                tint = palette.text
            )
        }
    }
}

/**
 * WeatherReading.symbolName 에 대응하는 날씨 기호를 Canvas 로 그린다(추가 아이콘 의존성 없음).
 * 24 단위 그리드를 [size] 안에 비례 배치하며, 색은 [tint] 하나로 통일해 팔레트와 맞춘다.
 * 지원: sun / cloud_sun / cloud / fog / drizzle / rain / snow / thunder (그 외는 cloud 로 표시).
 */
@Composable
fun WeatherSymbolIcon(
    symbolName: String,
    tint: Color,
    size: Dp = 18.dp,
    modifier: Modifier = Modifier
) {
    Canvas(modifier = modifier.size(size)) {
        val s = min(this.size.width, this.size.height) / 24f
        val originX = (this.size.width - 24f * s) / 2f
        val originY = (this.size.height - 24f * s) / 2f
        val p: (Float, Float) -> Offset = { x, y -> Offset(originX + x * s, originY + y * s) }
        val lineWidth = 1.6f * s

        when (symbolName) {
            "sun" -> drawSunSymbol(p, s, cx = 12f, cy = 12f, radius = 4f, rayStart = 6.2f, rayEnd = 8.6f, tint = tint, lineWidth = lineWidth)
            "cloud_sun" -> {
                drawSunSymbol(p, s, cx = 8.5f, cy = 8.5f, radius = 2.8f, rayStart = 4.3f, rayEnd = 6.2f, tint = tint, lineWidth = lineWidth)
                drawCloudSymbol(p, s, cx = 14f, cy = 14.5f, scale = 0.8f, tint = tint)
            }
            "fog" -> {
                drawCloudSymbol(p, s, cx = 12f, cy = 9f, scale = 0.85f, tint = tint)
                drawLine(tint, p(5f, 17f), p(19f, 17f), strokeWidth = lineWidth, cap = StrokeCap.Round)
                drawLine(tint, p(7f, 20.5f), p(17f, 20.5f), strokeWidth = lineWidth, cap = StrokeCap.Round)
            }
            "drizzle" -> {
                drawCloudSymbol(p, s, cx = 12f, cy = 9f, scale = 0.85f, tint = tint)
                for (x in listOf(8f, 12f, 16f)) {
                    drawLine(tint, p(x, 17f), p(x - 0.6f, 18.8f), strokeWidth = lineWidth, cap = StrokeCap.Round)
                }
            }
            "rain" -> {
                drawCloudSymbol(p, s, cx = 12f, cy = 9f, scale = 0.85f, tint = tint)
                for (x in listOf(8.5f, 12.5f, 16.5f)) {
                    drawLine(tint, p(x, 16.5f), p(x - 1.4f, 21f), strokeWidth = lineWidth, cap = StrokeCap.Round)
                }
            }
            "snow" -> {
                drawCloudSymbol(p, s, cx = 12f, cy = 9f, scale = 0.85f, tint = tint)
                for (x in listOf(8f, 12f, 16f)) {
                    drawCircle(tint, radius = 1.1f * s, center = p(x, 18.5f))
                }
            }
            "thunder" -> {
                drawCloudSymbol(p, s, cx = 12f, cy = 8.5f, scale = 0.85f, tint = tint)
                val bolt = Path().apply {
                    val pts = listOf(
                        Pair(13f, 13.5f), Pair(9.5f, 18.5f), Pair(12f, 18.5f),
                        Pair(10.5f, 23f), Pair(15f, 17f), Pair(12.5f, 17f), Pair(14.2f, 13.5f)
                    )
                    moveTo(p(pts[0].first, pts[0].second).x, p(pts[0].first, pts[0].second).y)
                    for (i in 1 until pts.size) lineTo(p(pts[i].first, pts[i].second).x, p(pts[i].first, pts[i].second).y)
                    close()
                }
                drawPath(bolt, tint)
            }
            else -> drawCloudSymbol(p, s, cx = 12f, cy = 12f, scale = 1f, tint = tint)
        }
    }
}

/** 채운 구름 실루엣: 원 두 개 + 둥근 밑판을 같은 색으로 겹쳐 하나의 덩어리로 보이게 한다. */
private fun DrawScope.drawCloudSymbol(
    p: (Float, Float) -> Offset,
    s: Float,
    cx: Float,
    cy: Float,
    scale: Float,
    tint: Color
) {
    val k = scale
    drawCircle(tint, radius = 3.5f * k * s, center = p(cx - 2.5f * k, cy + 0.5f * k))
    drawCircle(tint, radius = 4.5f * k * s, center = p(cx + 1.5f * k, cy - 1f * k))
    val topLeft = p(cx - 6.5f * k, cy)
    drawRoundRect(
        color = tint,
        topLeft = topLeft,
        size = Size(13f * k * s, 4f * k * s),
        cornerRadius = CornerRadius(2f * k * s, 2f * k * s)
    )
}

/** 채운 해 + 8방향 광선. */
private fun DrawScope.drawSunSymbol(
    p: (Float, Float) -> Offset,
    s: Float,
    cx: Float,
    cy: Float,
    radius: Float,
    rayStart: Float,
    rayEnd: Float,
    tint: Color,
    lineWidth: Float
) {
    drawCircle(tint, radius = radius * s, center = p(cx, cy))
    for (i in 0 until 8) {
        val angle = i * Math.PI / 4.0
        val start = p((cx + cos(angle) * rayStart).toFloat(), (cy + sin(angle) * rayStart).toFloat())
        val end = p((cx + cos(angle) * rayEnd).toFloat(), (cy + sin(angle) * rayEnd).toFloat())
        drawLine(tint, start, end, strokeWidth = lineWidth, cap = StrokeCap.Round)
    }
}
