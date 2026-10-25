package com.armsone.ccmb.model

import java.time.Instant
import java.util.Date

enum class SnapshotOrigin {
    CLOUD, PICKED_FILE, NAS, SAVED_COPY
}

enum class PreferredSource {
    CLOUD, FILE, NAS
}

data class UsageWindow(
    val id: String,
    val label: String,
    val remainingPercent: Double? = null,
    val resetsAt: Date? = null,
    val resetText: String? = null,
    val fetchedAt: Date? = null,
    val unavailabilityNote: String? = null
)

data class ModelWeeklyLimit(
    val id: String,
    val modelName: String,
    val remainingPercent: Double? = null,
    val resetsAt: Date? = null
)

data class ExecutionHost(
    val id: String,
    val hostname: String,
    val currentRole: String?,
    val state: String?,
    val accountRefs: List<String> = emptyList()
)

data class NASHostStatus(
    val executionHosts: List<ExecutionHost> = emptyList(),
    val autoSwitchEnabled: Boolean? = null,
    val autoSwitchAvailable: Boolean? = null,
    val isCached: Boolean = false
) {
    fun markingCached(): NASHostStatus = copy(isCached = true)
}

data class ServiceUsage(
    val service: Service,
    val account: String? = null,
    var accountDisplay: String? = null,
    val windows: List<UsageWindow> = emptyList(),
    val creditBalance: Double? = null,
    val monthlyUsedCredits: Double? = null,
    val creditUnlimited: Boolean = false,
    val creditLabel: String? = null,
    val organizationName: String? = null,
    val planTitle: String? = null,
    val model: String? = null,
    val fetchedAt: Date? = null,
    val status: String? = null,
    val errorReason: String? = null,
    val isLastKnown: Boolean = false,
    val stale: Boolean = false,
    val modelWeeklyLimits: List<ModelWeeklyLimit> = emptyList(),
    val codexResetCreditsAvailable: Int? = null,
    val codexResetCreditExpirations: List<Date> = emptyList(),
    val claudeLimitResetsCount: Int? = null,
    val claudeLimitResetsExpiresAt: Date? = null,
    var nasHostStatus: NASHostStatus? = null
) {
    fun window(id: String): UsageWindow? = windows.firstOrNull { it.id == id }

    val weeklyWindow: UsageWindow?
        get() = window("weekly")

    val fiveHourWindow: UsageWindow?
        get() = window("fiveHour") ?: window("session")

    val fableWeeklyWindow: UsageWindow?
        get() = window("fableWeekly") ?: modelWeeklyLimits.firstOrNull {
            it.modelName.lowercase().contains("fable")
        }?.let {
            UsageWindow(
                id = "fableWeekly",
                label = "페이블",
                remainingPercent = it.remainingPercent,
                resetsAt = it.resetsAt
            )
        }
}

data class UsageConsumptionPoint(
    val at: Date,
    val amount: Double,
    val segmentId: String? = null
)

data class NASConsumptionHistory(
    val schemaVersion: Int,
    val source: String = "nas",
    val intervalSeconds: Int = 180,
    val slotCount: Int = 40,
    val collectedAt: Date? = null,
    val generatedAt: Date? = null,
    val windowSeconds: Double = 86400.0,
    val gapSeconds: Double = 900.0,
    val codex: List<UsageConsumptionPoint> = emptyList(),
    val codexCredits: List<UsageConsumptionPoint> = emptyList(),
    val claude: List<UsageConsumptionPoint> = emptyList(),
    val claudeFable: List<UsageConsumptionPoint> = emptyList(),
    val gemini: List<UsageConsumptionPoint> = emptyList(),
    val gemini2: List<UsageConsumptionPoint> = emptyList(),
    val gemini3: List<UsageConsumptionPoint> = emptyList()
) {
    fun seriesFor(service: Service, codexUsesCredits: Boolean = false): List<UsageConsumptionPoint> = when (service) {
        Service.CODEX -> if (codexUsesCredits && codexCredits.isNotEmpty()) codexCredits else codex
        Service.CLAUDE -> claude
        Service.GEMINI -> gemini
        Service.GEMINI2 -> gemini2
        Service.GEMINI3 -> gemini3
        Service.GROK -> emptyList()
    }
}

data class UsageSnapshot(
    val fetchedAt: Date? = null,
    val publishedAt: Date? = null,
    val macAppVersion: String? = null,
    val services: Map<Service, ServiceUsage> = emptyMap(),
    val consumptionHistory: NASConsumptionHistory? = null,
    val generatedAt: Date? = null,
    var collectionBusy: Boolean = false,
    var nasHostStatus: NASHostStatus? = null
) {
    companion object {
        const val nasHistory24hWindowSeconds: Double = 86400.0
        const val staleAfterSeconds: Double = 3600.0
        const val nasHistoryMaxBytes: Int = 32768
        const val nasHistoryV2MaxBytes: Int = 524288
        const val nasHistoryV3MaxBytes: Int = 262144
    }

    val newestFetchedAt: Date?
        get() = generatedAt ?: fetchedAt ?: services.values.mapNotNull { it.fetchedAt }.maxOrNull()

    fun isStale(now: Date = Date()): Boolean {
        val stamp = newestFetchedAt ?: return false
        return (now.time - stamp.time) > (staleAfterSeconds * 1000)
    }

    fun markingLastKnown(lastKnownServiceNames: Set<String>): UsageSnapshot {
        if (lastKnownServiceNames.isEmpty()) return this
        val updated = services.toMutableMap()
        for ((service, usage) in services) {
            if (lastKnownServiceNames.contains(service.rawValue)) {
                updated[service] = usage.copy(isLastKnown = true, stale = true)
            }
        }
        return copy(services = updated)
    }

    fun markingNASHostStatusCached(): UsageSnapshot {
        val updated = services.toMutableMap()
        for ((service, usage) in services) {
            if (usage.nasHostStatus != null) {
                updated[service] = usage.copy(nasHostStatus = usage.nasHostStatus?.markingCached())
            }
        }
        return copy(
            nasHostStatus = nasHostStatus?.markingCached(),
            services = updated
        )
    }
}
