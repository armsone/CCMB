package com.armsone.ccmb.ui

import androidx.compose.foundation.Canvas
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
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.armsone.ccmb.model.Account24hModel
import com.armsone.ccmb.model.ConsumptionBucket
import com.armsone.ccmb.model.ConsumptionBucketing
import com.armsone.ccmb.theme.LocalCCMBPalette
import java.util.Date
import kotlin.math.max
import kotlin.math.min

private data class Node(
    val point: Offset,
    val isEdge: Boolean
)

@Composable
fun Account24hPlot(
    model: Account24hModel?,
    placeholder: String,
    coverage: String? = null,
    fixedHeight: Dp? = null,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current
    val gutterWidth = 32.dp
    val topPad = 5.dp
    val bottomPad = 3.dp

    val a11yDesc = model?.accessibilityDescription() ?: "24시간 사용 추이, $placeholder"

    Column(
        modifier = modifier
            .fillMaxWidth()
            .then(if (fixedHeight != null) Modifier.height(fixedHeight) else Modifier)
            .semantics { contentDescription = a11yDesc }
    ) {
        Row(
            modifier = Modifier
                .weight(1f, fill = fixedHeight != null)
                .fillMaxWidth()
        ) {
            // Left gutter with y-axis tick labels
            Box(
                modifier = Modifier
                    .width(gutterWidth)
                    .fillMaxHeight()
                    .padding(top = topPad, bottom = bottomPad)
            ) {
                if (model != null && model.hasData) {
                    val topLabel = if (model.usesCreditsScale) model.axisText(model.yMax) else "${model.axisText(model.yMax)}%"
                    Text(
                        text = topLabel,
                        color = palette.muted,
                        fontSize = 9.sp,
                        fontFamily = FontFamily.Monospace,
                        textAlign = TextAlign.End,
                        maxLines = 1,
                        softWrap = false,
                        modifier = Modifier
                            .fillMaxWidth()
                            .align(Alignment.TopEnd)
                    )
                    Text(
                        text = model.axisText(model.yMax / 2),
                        color = palette.muted,
                        fontSize = 9.sp,
                        fontFamily = FontFamily.Monospace,
                        textAlign = TextAlign.End,
                        maxLines = 1,
                        softWrap = false,
                        modifier = Modifier
                            .fillMaxWidth()
                            .align(Alignment.CenterEnd)
                    )
                    Text(
                        text = model.axisText(0.0),
                        color = palette.muted,
                        fontSize = 9.sp,
                        fontFamily = FontFamily.Monospace,
                        textAlign = TextAlign.End,
                        maxLines = 1,
                        softWrap = false,
                        modifier = Modifier
                            .fillMaxWidth()
                            .align(Alignment.BottomEnd)
                    )
                }
            }

            Spacer(modifier = Modifier.width(4.dp))

            // Canvas area
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight(),
                contentAlignment = Alignment.Center
            ) {
                Restrained24hLineAreaCanvas(
                    model = model,
                    color = model?.color ?: palette.muted,
                    topPad = topPad,
                    bottomPad = bottomPad
                )

                if (model == null) {
                    Text(
                        text = placeholder,
                        color = palette.muted,
                        fontSize = 10.sp,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(horizontal = 8.dp)
                    )
                } else if (!model.hasData) {
                    Text(
                        text = "최근 24시간 기록 없음",
                        color = palette.muted,
                        fontSize = 10.sp,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(horizontal = 8.dp)
                    )
                }
            }
        }

        // Bottom timeline text: "지금" ... "24시간 전"
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = gutterWidth + 4.dp, top = 2.dp)
        ) {
            Text(
                text = "지금",
                color = palette.muted,
                fontSize = 10.sp
            )
            Spacer(modifier = Modifier.weight(1f))
            if (coverage != null) {
                Text(
                    text = coverage,
                    color = palette.muted,
                    fontSize = 10.sp
                )
                Spacer(modifier = Modifier.weight(1f))
            }
            Text(
                text = "24시간 전",
                color = palette.muted,
                fontSize = 10.sp
            )
        }
    }
}

@Composable
fun Restrained24hLineAreaCanvas(
    model: Account24hModel?,
    color: Color,
    topPad: Dp,
    bottomPad: Dp,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current

    Canvas(modifier = modifier.fillMaxSize()) {
        val topPadPx = topPad.toPx()
        val bottomPadPx = bottomPad.toPx()
        val usableHeight = max(1f, size.height - topPadPx - bottomPadPx)
        val baselineY = size.height - bottomPadPx

        val windowSeconds = model?.windowSeconds ?: 86400.0
        val anchorDate = model?.anchorDate ?: Date()
        val yMax = model?.yMax ?: 100.0

        fun xPos(date: Date): Float {
            val ageMs = max(0L, min((windowSeconds * 1000).toLong(), anchorDate.time - date.time))
            return ((ageMs / (windowSeconds * 1000.0)) * size.width).toFloat()
        }

        fun yPos(amount: Double): Float {
            val clamped = max(0.0, min(1.0, amount / max(0.0001, yMax)))
            return (baselineY - (clamped * usableHeight)).toFloat()
        }

        // 1. Shading uncollected older region on the right (< 23.5h coverage)
        val earliest = model?.earliest
        if (earliest != null) {
            val earliestX = xPos(earliest)
            if (earliestX < size.width - 6) {
                drawRect(
                    color = palette.text.copy(alpha = 0.04f),
                    topLeft = Offset(earliestX, 0f),
                    size = Size(size.width - earliestX, size.height)
                )
                drawLine(
                    color = palette.text.copy(alpha = 0.28f),
                    start = Offset(earliestX, topPadPx),
                    end = Offset(earliestX, baselineY),
                    strokeWidth = 1.dp.toPx(),
                    pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx()), 0f)
                )
            }
        }

        // 2. Horizontal reference grid lines (top 100%, mid 50%, baseline 0%)
        val dashEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx()), 0f)
        for (fraction in listOf(0.0f, 0.5f, 1.0f)) {
            val y = topPadPx + fraction * usableHeight
            val alpha = if (fraction == 1.0f) 0.9f else 0.7f
            drawLine(
                color = palette.border2.copy(alpha = alpha),
                start = Offset(0f, y),
                end = Offset(size.width, y),
                strokeWidth = 0.75.dp.toPx(),
                pathEffect = dashEffect
            )
        }

        // 3. Draw buckets & series
        if (model != null && model.hasData) {
            val runs = ConsumptionBucketing.runs(model.buckets, model.maxContiguousGap)
            for (run in runs) {
                val nodes = run.map { bucket ->
                    Node(
                        point = Offset(xPos(bucket.midpoint), yPos(bucket.amount)),
                        isEdge = bucket.isEdge
                    )
                }

                val complete = nodes.filter { !it.isEdge }.map { it.point }
                if (complete.size >= 2) {
                    val head = complete.first()
                    val tail = complete.last()
                    val areaPath = Path().apply {
                        moveTo(head.x, baselineY)
                        for (pt in complete) {
                            lineTo(pt.x, pt.y)
                        }
                        lineTo(tail.x, baselineY)
                        close()
                    }

                    val areaTopY = min(complete.minOfOrNull { it.y } ?: baselineY, baselineY - 1f)
                    drawPath(
                        path = areaPath,
                        brush = Brush.verticalGradient(
                            colors = listOf(color.copy(alpha = 0.40f), color.copy(alpha = 0.12f)),
                            startY = areaTopY,
                            endY = baselineY
                        )
                    )
                }

                // Connecting stroke between consecutive points
                for (i in 0 until nodes.size - 1) {
                    val newer = nodes[i]
                    val older = nodes[i + 1]
                    val partial = newer.isEdge || older.isEdge

                    drawLine(
                        color = color,
                        start = newer.point,
                        end = older.point,
                        strokeWidth = 1.5.dp.toPx(),
                        pathEffect = if (partial) PathEffect.dashPathEffect(
                            floatArrayOf(3.dp.toPx(), 2.5.dp.toPx()),
                            0f
                        ) else null
                    )
                }

                // Node dots
                for (node in nodes) {
                    if (node.isEdge || nodes.size == 1) {
                        val radius = 2.5.dp.toPx()
                        if (node.isEdge) {
                            // Hollow marker for edge/in-progress buckets
                            drawCircle(
                                color = color,
                                radius = radius,
                                center = node.point,
                                style = Stroke(width = 1.2.dp.toPx())
                            )
                        } else {
                            // Filled dot
                            drawCircle(
                                color = color,
                                radius = radius,
                                center = node.point
                            )
                        }
                    }
                }
            }
        }
    }
}
