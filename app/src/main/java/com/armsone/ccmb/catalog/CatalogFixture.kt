package com.armsone.ccmb.catalog

import com.armsone.ccmb.model.NASConsumptionHistory
import com.armsone.ccmb.model.Service
import com.armsone.ccmb.model.ServiceUsage
import com.armsone.ccmb.model.UsageConsumptionPoint
import com.armsone.ccmb.model.UsageSnapshot
import com.armsone.ccmb.model.UsageWindow
import java.util.Date

object CatalogFixture {
    fun createPopulatedSnapshot(): UsageSnapshot {
        val now = Date()
        val oneHourMs = 3600 * 1000L
        val oneDayMs = 24 * oneHourMs

        // Realistic points across past 10 hours (sampled every 3 minutes = 180s, NAS cadence)
        fun generatePoints(baseAmount: Double, variance: Double): List<UsageConsumptionPoint> {
            val list = mutableListOf<UsageConsumptionPoint>()
            val intervalMs = 180 * 1000L // 3 minutes, within maxContiguousGap (900s)
            for (i in 0 until 200) {
                val time = Date(now.time - i * intervalMs)
                val wave = Math.sin(i.toDouble() / 8.0) * variance
                val amt = (baseAmount + wave).coerceAtLeast(0.0)
                list.add(UsageConsumptionPoint(at = time, amount = amt, segmentId = "main_segment"))
            }
            return list
        }

        val codexPoints = generatePoints(1.8, 1.0)
        val claudePoints = generatePoints(2.2, 1.4)
        val geminiPoints = generatePoints(2.5, 1.5)
        val gemini2Points = generatePoints(1.4, 0.9)
        val gemini3Points = generatePoints(0.6, 0.4)

        val history = NASConsumptionHistory(
            schemaVersion = 3,
            source = "nas-catalog-fixture",
            intervalSeconds = 180,
            slotCount = 40,
            generatedAt = now,
            codex = codexPoints,
            codexCredits = emptyList(),
            claude = claudePoints,
            gemini = geminiPoints,
            gemini2 = gemini2Points,
            gemini3 = gemini3Points
        )

        val codexExpirations = listOf(
            Date(now.time + 3 * oneDayMs + 2 * oneHourMs),
            Date(now.time + 5 * oneDayMs + 4 * oneHourMs)
        )

        val codexUsage = ServiceUsage(
            service = Service.CODEX,
            account = "catalog.user@example.com",
            accountDisplay = "catalog.user",
            windows = listOf(
                UsageWindow(
                    id = "weekly",
                    label = "주간",
                    remainingPercent = 85.0,
                    resetsAt = Date(now.time + 2 * oneDayMs)
                )
            ),
            creditBalance = 88889.0,
            creditUnlimited = false,
            codexResetCreditsAvailable = 2,
            codexResetCreditExpirations = codexExpirations,
            fetchedAt = now,
            status = "ok"
        )

        val claudeUsage = ServiceUsage(
            service = Service.CLAUDE,
            account = "catalog.user@example.com",
            accountDisplay = "catalog.user",
            windows = listOf(
                UsageWindow(
                    id = "fableWeekly",
                    label = "페이블",
                    remainingPercent = 92.0,
                    resetsAt = Date(now.time + 3 * oneDayMs)
                ),
                UsageWindow(
                    id = "fiveHour",
                    label = "세션",
                    remainingPercent = 74.0,
                    resetsAt = Date(now.time + 3 * oneHourMs)
                ),
                UsageWindow(
                    id = "weekly",
                    label = "주간",
                    remainingPercent = 81.0,
                    resetsAt = Date(now.time + 4 * oneDayMs)
                )
            ),
            fetchedAt = now,
            status = "ok"
        )

        val gemini1Usage = ServiceUsage(
            service = Service.GEMINI,
            account = "catalog.account1@gmail.com",
            accountDisplay = "catalog.account1",
            windows = listOf(
                UsageWindow(
                    id = "fiveHour",
                    label = "세션",
                    remainingPercent = 90.0,
                    resetsAt = Date(now.time + 4 * oneHourMs)
                ),
                UsageWindow(
                    id = "weekly",
                    label = "주간",
                    remainingPercent = 78.0,
                    resetsAt = Date(now.time + 5 * oneDayMs)
                )
            ),
            fetchedAt = now,
            status = "ok"
        )

        val gemini2Usage = ServiceUsage(
            service = Service.GEMINI2,
            account = "catalog.account2@gmail.com",
            accountDisplay = "catalog.account2",
            windows = listOf(
                UsageWindow(
                    id = "fiveHour",
                    label = "세션",
                    remainingPercent = 65.0,
                    resetsAt = Date(now.time + 2 * oneHourMs)
                ),
                UsageWindow(
                    id = "weekly",
                    label = "주간",
                    remainingPercent = 55.0,
                    resetsAt = Date(now.time + 3 * oneDayMs)
                )
            ),
            fetchedAt = now,
            status = "ok"
        )

        val gemini3Usage = ServiceUsage(
            service = Service.GEMINI3,
            account = "catalog.account3@gmail.com",
            accountDisplay = "catalog.account3",
            windows = listOf(
                UsageWindow(
                    id = "fiveHour",
                    label = "세션",
                    remainingPercent = 100.0,
                    resetsAt = Date(now.time + 5 * oneHourMs)
                ),
                UsageWindow(
                    id = "weekly",
                    label = "주간",
                    remainingPercent = 95.0,
                    resetsAt = Date(now.time + 6 * oneDayMs)
                )
            ),
            fetchedAt = now,
            status = "ok"
        )

        return UsageSnapshot(
            fetchedAt = now,
            generatedAt = now,
            macAppVersion = "0.7.6",
            services = mapOf(
                Service.CODEX to codexUsage,
                Service.CLAUDE to claudeUsage,
                Service.GEMINI to gemini1Usage,
                Service.GEMINI2 to gemini2Usage,
                Service.GEMINI3 to gemini3Usage
            ),
            consumptionHistory = history
        )
    }
}
