package com.armsone.ccmb.format

import com.armsone.ccmb.model.ServiceUsage
import java.text.DecimalFormat
import java.text.DecimalFormatSymbols
import java.text.SimpleDateFormat
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import java.util.Date
import java.util.Locale
import kotlin.math.floor

object CCMBFormat {
    private val koreaLocale = Locale.KOREAN

    fun percent(value: Double?): String {
        return if (value != null) String.format(Locale.US, "%.1f%%", value) else "정보 없음"
    }

    fun credits(value: Double?): String {
        return if (value != null) String.format(Locale.US, "%.0f", value) else "정보 없음"
    }

    fun resetTime(date: Date?): String {
        if (date == null) return "정보 없음"
        val sdf = SimpleDateFormat("M/d(E) HH:mm", koreaLocale)
        return sdf.format(date)
    }

    fun monthDayTime(date: Date): String {
        val sdf = SimpleDateFormat("MM/dd HH:mm", Locale.US)
        return sdf.format(date)
    }

    fun monthDayWeekdayTime(date: Date): String {
        val sdf = SimpleDateFormat("MM/dd(E) HH:mm", koreaLocale)
        return sdf.format(date)
    }

    /**
     * 카드 시각: 오늘 'HH:mm', 내일 '내일 HH:mm', 모레 '모레 HH:mm', 글피 이후와 지난 시각 'MM/dd(요일) HH:mm'.
     * 날짜 경계는 기기 달력의 자정 기준이다.
     */
    fun quotaTime(date: Date, now: Date = Date()): String {
        val zone = ZoneId.systemDefault()
        val nowDate = now.toInstant().atZone(zone).toLocalDate()
        val targetDate = date.toInstant().atZone(zone).toLocalDate()
        val dayDiff = ChronoUnit.DAYS.between(nowDate, targetDate)

        val clockFormat = SimpleDateFormat("HH:mm", Locale.US)
        val clock = clockFormat.format(date)

        return when (dayDiff) {
            0L -> clock
            1L -> "내일 $clock"
            2L -> "모레 $clock"
            else -> monthDayWeekdayTime(date)
        }
    }

    /**
     * Mac/NAS가 마지막으로 사용량을 수집한 시각.
     * 오늘은 시각만, 어제·그제는 한글 날짜, 그 이전은 월/일과 24시간 시각을 표시한다.
     */
    fun macCollectionTime(date: Date?, now: Date = Date()): String {
        if (date == null) return "시각 정보 없음"
        val zone = ZoneId.systemDefault()
        val nowDate = now.toInstant().atZone(zone).toLocalDate()
        val targetDate = date.toInstant().atZone(zone).toLocalDate()
        val dayDiff = ChronoUnit.DAYS.between(targetDate, nowDate)

        val clockFormat = SimpleDateFormat("HH:mm", Locale.US)
        val clock = clockFormat.format(date)

        return when (dayDiff) {
            0L -> clock
            1L -> "어제 $clock"
            2L -> "그제 $clock"
            else -> {
                val sdf = SimpleDateFormat("M/d HH:mm", Locale.US)
                sdf.format(date)
            }
        }
    }

    /**
     * "방금", "3분 전" 형태의 상대 시간.
     */
    fun relativeAge(date: Date?, now: Date = Date()): String {
        if (date == null) return "시각 정보 없음"
        val diffMs = now.time - date.time
        if (diffMs < 60_000) return "방금"

        val seconds = diffMs / 1000
        val minutes = seconds / 60
        val hours = minutes / 60
        val days = hours / 24

        return when {
            minutes < 60 -> "${minutes}분 전"
            hours < 24 -> "${hours}시간 전"
            else -> "${days}일 전"
        }
    }

    /**
     * 쉼표와 정수만(예: 88,889). 소수는 올림·반올림 없이 버린다.
     */
    fun groupedInteger(value: Double): String {
        val floored = floor(value).toLong()
        val symbols = DecimalFormatSymbols(Locale.KOREA)
        val df = DecimalFormat("#,###", symbols)
        return df.format(floored)
    }

    /**
     * 실제 계정 표시값에서 이메일 도메인을 뗀 ID. 값이 없으면 nil.
     */
    fun accountID(usage: ServiceUsage): String? {
        val candidates = listOfNotNull(usage.accountDisplay, usage.account)
        for (candidate in candidates) {
            val trimmed = candidate.trim()
            if (trimmed.isEmpty()) continue
            val atIndex = trimmed.indexOf('@')
            if (atIndex > 0) {
                val local = trimmed.substring(0, atIndex)
                if (local.isNotEmpty()) return local
            } else {
                return trimmed
            }
        }
        return null
    }

    /**
     * 초기화 텍스트(문자열 형태) 정규화
     */
    fun quotaResetText(source: String?, now: Date = Date()): String? {
        if (source.isNullOrBlank()) return null
        val trimmed = source.trim()
        // Try parsing ISO8601 or common formats if needed
        return try {
            val instant = Instant.parse(trimmed)
            quotaTime(Date.from(instant), now)
        } catch (_: Exception) {
            trimmed
        }
    }

    fun resetText(source: String?): String? {
        if (source.isNullOrBlank()) return null
        val trimmed = source.trim()
        return try {
            val instant = Instant.parse(trimmed)
            resetTime(Date.from(instant))
        } catch (_: Exception) {
            trimmed
        }
    }
}
