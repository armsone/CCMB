package com.armsone.ccmb.model

import androidx.compose.ui.graphics.Color
import java.text.DecimalFormat
import java.text.DecimalFormatSymbols
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

data class ConsumptionBucket(
    val start: Date,
    val from: Date,
    val to: Date,
    val amount: Double,
    val sampleCount: Int,
    val firstAt: Date,
    val lastAt: Date,
    val segmentId: String?,
    val isInProgress: Boolean,
    var isClipped: Boolean,
    val hasGap: Boolean
) {
    val isEdge: Boolean
        get() = isInProgress || isClipped

    val midpoint: Date
        get() = Date((from.time + to.time) / 2)
}

object ConsumptionBucketing {
    const val bucketSeconds: Double = 1800.0

    fun boundary(date: Date): Date {
        val offset = TimeZone.getDefault().getOffset(date.time) / 1000.0
        val local = (date.time / 1000.0) + offset
        val boundarySeconds = floor(local / bucketSeconds) * bucketSeconds - offset
        return Date((boundarySeconds * 1000.0).toLong())
    }

    private data class Key(
        val start: Long,
        val segmentId: String?
    )

    fun buckets(
        points: List<UsageConsumptionPoint>,
        gap: Double,
        anchor: Date,
        windowStart: Date,
        earliest: Date
    ): List<ConsumptionBucket> {
        val groups = mutableMapOf<Key, MutableList<Pair<Date, Double>>>()
        for (point in points) {
            if (point.at.time >= windowStart.time) {
                val at = if (point.at.time < anchor.time) point.at else anchor
                val key = Key(boundary(at).time, point.segmentId)
                groups.getOrPut(key) { mutableListOf() }.add(Pair(at, point.amount))
            }
        }

        val lowerBound = if (windowStart.time > earliest.time) windowStart else earliest
        val result = mutableListOf<ConsumptionBucket>()

        for ((key, entries) in groups) {
            val ordered = entries.sortedBy { it.first.time }
            if (ordered.isEmpty()) continue
            val first = ordered.first()
            val last = ordered.last()

            val start = Date(key.start)
            val end = Date(key.start + (bucketSeconds * 1000).toLong())
            val from = if (start.time > lowerBound.time) start else lowerBound
            val to = if (from.time > (if (end.time < anchor.time) end else anchor).time) {
                from
            } else {
                if (end.time < anchor.time) end else anchor
            }

            var hasGap = false
            for (i in 0 until ordered.size - 1) {
                val older = ordered[i]
                val newer = ordered[i + 1]
                if ((newer.first.time - older.first.time) > gap * 1000) {
                    hasGap = true
                    break
                }
            }

            val amountSum = ordered.sumOf { max(0.0, it.second) }
            val isInProgress = end.time > anchor.time
            val isClipped = start.time < lowerBound.time

            result.add(
                ConsumptionBucket(
                    start = start,
                    from = from,
                    to = to,
                    amount = amountSum,
                    sampleCount = ordered.size,
                    firstAt = first.first,
                    lastAt = last.first,
                    segmentId = key.segmentId,
                    isInProgress = isInProgress,
                    isClipped = isClipped,
                    hasGap = hasGap
                )
            )
        }

        result.sortWith { a, b ->
            if (a.start.time != b.start.time) {
                b.start.time.compareTo(a.start.time) // Newest first
            } else {
                b.lastAt.time.compareTo(a.lastAt.time)
            }
        }

        if (result.isNotEmpty()) {
            val oldest = result.last()
            if ((oldest.firstAt.time - oldest.from.time) > gap * 1000) {
                oldest.isClipped = true
            }
        }

        return result
    }

    fun runs(buckets: List<ConsumptionBucket>, gap: Double): List<List<ConsumptionBucket>> {
        val result = mutableListOf<List<ConsumptionBucket>>()
        var current = mutableListOf<ConsumptionBucket>()

        for (bucket in buckets) {
            val newer = current.lastOrNull()
            if (newer != null) {
                val diffSeconds = (newer.start.time - bucket.start.time) / 1000.0
                val neighbours = (diffSeconds / bucketSeconds).roundToInt() == 1
                val sameSegment = if (newer.segmentId != null && bucket.segmentId != null) {
                    newer.segmentId == bucket.segmentId
                } else true

                val gapExceeded = (newer.firstAt.time - bucket.lastAt.time) > gap * 1000

                if (!neighbours || !sameSegment || gapExceeded) {
                    result.add(current)
                    current = mutableListOf()
                }
            }
            current.add(bucket)
        }
        if (current.isNotEmpty()) {
            result.add(current)
        }
        return result
    }
}

data class Account24hModel(
    val buckets: List<ConsumptionBucket>,
    val earliest: Date?,
    val yMax: Double,
    val usesCreditsScale: Boolean,
    val unit: String,
    val color: Color,
    val anchorDate: Date,
    val windowSeconds: Double,
    val maxContiguousGap: Double
) {
    val hasData: Boolean
        get() = buckets.isNotEmpty()

    companion object {
        fun axisMax(peak: Double, usesCreditsScale: Boolean): Double {
            if (peak <= 0.0) {
                return if (usesCreditsScale) 10.0 else 5.0
            }
            return peak
        }

        fun create(
            samples: List<UsageConsumptionPoint>,
            anchorDate: Date,
            windowSeconds: Double = UsageSnapshot.nasHistory24hWindowSeconds,
            maxContiguousGap: Double = 900.0,
            usesCreditsScale: Boolean = false,
            unit: String = "",
            color: Color
        ): Account24hModel {
            val windowStart = Date(anchorDate.time - (windowSeconds * 1000).toLong())
            val filtered = samples
                .filter { it.at.time >= windowStart.time && it.at.time <= anchorDate.time + 60_000 }
                .sortedByDescending { it.at.time }

            val earliest = filtered.minOfOrNull { it.at }
            val buckets = ConsumptionBucketing.buckets(
                points = filtered,
                gap = maxContiguousGap,
                anchor = anchorDate,
                windowStart = windowStart,
                earliest = earliest ?: windowStart
            )
            val peak = buckets.maxOfOrNull { it.amount } ?: 0.0
            val yMax = axisMax(peak, usesCreditsScale)

            return Account24hModel(
                buckets = buckets,
                earliest = earliest,
                yMax = yMax,
                usesCreditsScale = usesCreditsScale,
                unit = unit,
                color = color,
                anchorDate = anchorDate,
                windowSeconds = windowSeconds,
                maxContiguousGap = maxContiguousGap
            )
        }
    }

    fun axisText(value: Double): String {
        if (value == 0.0) return "0"
        return if (usesCreditsScale) {
            if (value == floor(value)) {
                val df = DecimalFormat("#,###", DecimalFormatSymbols(Locale.KOREA))
                df.format(value.toLong())
            } else {
                val df = DecimalFormat("#,##0.##", DecimalFormatSymbols(Locale.KOREA))
                df.format(value)
            }
        } else {
            if (value == floor(value)) {
                String.format(Locale.US, "%.0f", value)
            } else {
                val df = DecimalFormat("0.##", DecimalFormatSymbols(Locale.US))
                val text = df.format(value)
                if (text == "0" && value > 0.0) {
                    DecimalFormat("0.###", DecimalFormatSymbols(Locale.US)).format(value)
                } else {
                    text
                }
            }
        }
    }

    fun accessibilityDescription(): String {
        val clockFormat = SimpleDateFormat("HH:mm", Locale.KOREA)
        val head = "24시간 사용 추이, 왼쪽 최신 ${clockFormat.format(anchorDate)}, 오른쪽 24시간 전"
        val latest = buckets.firstOrNull()
        val peak = buckets.maxOfOrNull { it.amount }
        if (latest == null || peak == null) {
            return "$head, 기록 없음"
        }
        val running = if (latest.isInProgress) "진행 중인 30분 " else "최근 30분 "
        val latestText = if (usesCreditsScale) "${axisText(floor(latest.amount))}$unit" else String.format(Locale.US, "%.1f%%", latest.amount)
        val peakText = if (usesCreditsScale) "${axisText(floor(peak))}$unit" else String.format(Locale.US, "%.1f%%", peak)
        return "$head, ${buckets.size}개 구간, ${running}소모 $latestText, 30분 최대 소모 $peakText"
    }
}
