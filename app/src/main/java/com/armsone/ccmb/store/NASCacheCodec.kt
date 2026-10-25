package com.armsone.ccmb.store

import android.content.Context
import android.util.AtomicFile
import com.armsone.ccmb.model.ExecutionHost
import com.armsone.ccmb.model.ModelWeeklyLimit
import com.armsone.ccmb.model.NASHostStatus
import com.armsone.ccmb.model.Service
import com.armsone.ccmb.model.ServiceUsage
import com.armsone.ccmb.model.UsageSnapshot
import com.armsone.ccmb.model.UsageWindow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.util.Date

object NASCacheCodec {
    const val SNAPSHOT_V2_FORMAT = "nas-v2"
    const val SNAPSHOT_LEGACY_FORMAT = "nas-legacy"
    const val MAX_SNAPSHOT_CACHE_BYTES = 262144

    private val serviceKeysV2 = listOf("service", "provider", "account_ref", "ok", "stale", "fetched_at", "account_display")
    private val itemKeys = listOf("name", "window", "window_minutes", "remaining_percent", "resets_at")

    fun sanitizeDocument(data: ByteArray, isV2: Boolean): JSONObject? {
        return try {
            val root = JSONObject(String(data, Charsets.UTF_8))
            if (isV2) {
                if (root.optInt("schema_version") != 2) return null
                val servicesArr = root.optJSONArray("services") ?: return null
                val sanitizedServices = JSONArray()
                for (i in 0 until servicesArr.length()) {
                    val svc = servicesArr.optJSONObject(i) ?: continue
                    val name = svc.optString("service")
                    if (Service.fromRaw(name) != null) {
                        sanitizedServices.put(sanitizeService(svc, serviceKeysV2))
                    }
                }
                val out = JSONObject()
                out.put("schema_version", 2)
                out.put("services", sanitizedServices)
                if (root.has("quota_origin")) out.put("quota_origin", root.get("quota_origin"))
                if (root.has("generated_at")) out.put("generated_at", root.get("generated_at"))
                if (root.has("execution_hosts")) out.put("execution_hosts", root.get("execution_hosts"))
                if (root.has("auto_switch_enabled")) out.put("auto_switch_enabled", root.get("auto_switch_enabled"))
                if (root.has("auto_switch_available")) out.put("auto_switch_available", root.get("auto_switch_available"))
                out
            } else {
                val report = root.optJSONObject("report") ?: return null
                val servicesArr = report.optJSONArray("services") ?: return null
                val sanitizedServices = JSONArray()
                for (i in 0 until servicesArr.length()) {
                    val svc = servicesArr.optJSONObject(i) ?: continue
                    sanitizedServices.put(sanitizeService(svc, listOf("service", "ok", "stale", "fetched_at", "account_display")))
                }
                JSONObject().put("report", JSONObject().put("services", sanitizedServices))
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun sanitizeService(service: JSONObject, keys: List<String>): JSONObject {
        val out = JSONObject()
        for (key in keys) {
            if (service.has(key)) out.put(key, service.get(key))
        }

        val err = service.opt("error")
        when (err) {
            is JSONObject -> {
                val errObj = JSONObject()
                if (err.has("code")) errObj.put("code", err.optString("code"))
                if (err.has("message")) errObj.put("message", err.optString("message"))
                out.put("error", errObj)
            }
            is String -> {
                out.put("error", JSONObject().put("code", "unknown"))
            }
            JSONObject.NULL -> out.put("error", JSONObject.NULL)
        }

        val itemsArr = service.optJSONArray("items")
        val sanitizedItems = JSONArray()
        if (itemsArr != null) {
            for (i in 0 until itemsArr.length()) {
                val item = itemsArr.optJSONObject(i) ?: continue
                val sanitizedItem = JSONObject()
                for (key in itemKeys) {
                    if (item.has(key)) sanitizedItem.put(key, item.get(key))
                }
                val credits = item.optJSONObject("credits")
                if (credits != null) {
                    val safeCredits = JSONObject()
                    if (credits.has("balance")) safeCredits.put("balance", credits.optDouble("balance"))
                    if (credits.has("unlimited")) safeCredits.put("unlimited", credits.optBoolean("unlimited"))
                    if (safeCredits.length() > 0) sanitizedItem.put("credits", safeCredits)
                }
                val codexDetails = item.optJSONObject("codex_details")
                if (codexDetails != null) {
                    val safeCodex = JSONObject()
                    if (codexDetails.has("plan_type")) safeCodex.put("plan_type", codexDetails.optString("plan_type"))
                    if (codexDetails.has("reset_credits_available")) safeCodex.put("reset_credits_available", codexDetails.optInt("reset_credits_available"))
                    if (codexDetails.has("reset_credit_expirations")) safeCodex.put("reset_credit_expirations", codexDetails.optJSONArray("reset_credit_expirations"))
                    if (safeCodex.length() > 0) sanitizedItem.put("codex_details", safeCodex)
                }
                val claudeDetails = item.optJSONObject("claude_details")
                if (claudeDetails != null) {
                    val safeClaude = JSONObject()
                    if (claudeDetails.has("plan_type")) safeClaude.put("plan_type", claudeDetails.optString("plan_type"))
                    if (claudeDetails.has("limit_resets")) safeClaude.put("limit_resets", claudeDetails.optJSONObject("limit_resets"))
                    if (safeClaude.length() > 0) sanitizedItem.put("claude_details", safeClaude)
                }
                sanitizedItems.put(sanitizedItem)
            }
        }
        out.put("items", sanitizedItems)

        val geminiDetails = service.optJSONObject("gemini_details")
        if (geminiDetails != null) {
            val safeGemini = JSONObject()
            if (geminiDetails.has("credit_balance")) safeGemini.put("credit_balance", geminiDetails.optDouble("credit_balance"))
            if (geminiDetails.has("credits_fetched_at")) safeGemini.put("credits_fetched_at", geminiDetails.optDouble("credits_fetched_at"))
            if (geminiDetails.has("credits_status")) safeGemini.put("credits_status", geminiDetails.optString("credits_status"))
            if (geminiDetails.has("plan_title")) safeGemini.put("plan_title", geminiDetails.optString("plan_title"))
            if (safeGemini.length() > 0) out.put("gemini_details", safeGemini)
        }

        return out
    }

    fun mergeLastKnown(
        incoming: JSONObject,
        previous: JSONObject?,
        isV2: Boolean
    ): Pair<JSONObject, Set<String>> {
        if (previous == null) return Pair(incoming, emptySet())

        val incomingServices = if (isV2) incoming.optJSONArray("services") else incoming.optJSONObject("report")?.optJSONArray("services")
        val previousServices = if (isV2) previous.optJSONArray("services") else previous.optJSONObject("report")?.optJSONArray("services")
        if (incomingServices == null || previousServices == null) return Pair(incoming, emptySet())

        val lastKnown = mutableSetOf<String>()
        val mergedList = JSONArray()

        for (i in 0 until incomingServices.length()) {
            val svc = incomingServices.optJSONObject(i) ?: continue
            val items = svc.optJSONArray("items")
            val ok = svc.optBoolean("ok", false)
            val name = svc.optString("service")

            if ((items == null || items.length() == 0) && !ok) {
                // Find old service with same identity
                var oldSvc: JSONObject? = null
                for (j in 0 until previousServices.length()) {
                    val prev = previousServices.optJSONObject(j) ?: continue
                    if (prev.optString("service") == name) {
                        if (isV2) {
                            if (prev.optString("provider") == svc.optString("provider") &&
                                prev.optString("account_ref") == svc.optString("account_ref")) {
                                oldSvc = prev
                                break
                            }
                        } else {
                            oldSvc = prev
                            break
                        }
                    }
                }

                val oldItems = oldSvc?.optJSONArray("items")
                if (oldItems != null && oldItems.length() > 0) {
                    val mergedSvc = JSONObject(svc.toString())
                    mergedSvc.put("items", oldItems)
                    if (oldSvc.has("fetched_at")) mergedSvc.put("fetched_at", oldSvc.get("fetched_at"))
                    mergedSvc.put("ok", false)
                    mergedSvc.put("stale", true)
                    lastKnown.add(name)
                    mergedList.put(mergedSvc)
                    continue
                }
            }
            mergedList.put(svc)
        }

        val out = JSONObject(incoming.toString())
        if (isV2) {
            out.put("services", mergedList)
        } else {
            val rep = out.optJSONObject("report") ?: JSONObject()
            rep.put("services", mergedList)
            out.put("report", rep)
        }
        return Pair(out, lastKnown)
    }

    fun parseSnapshot(doc: JSONObject, isV2: Boolean): UsageSnapshot {
        val servicesMap = mutableMapOf<Service, ServiceUsage>()
        val servicesArr = if (isV2) doc.optJSONArray("services") else doc.optJSONObject("report")?.optJSONArray("services")

        var hostStatus: NASHostStatus? = null
        if (isV2) {
            val execHostsArr = doc.optJSONArray("execution_hosts")
            val hostList = mutableListOf<ExecutionHost>()
            if (execHostsArr != null) {
                for (i in 0 until execHostsArr.length()) {
                    val h = execHostsArr.optJSONObject(i) ?: continue
                    val refs = mutableListOf<String>()
                    val refsArr = h.optJSONArray("account_refs")
                    if (refsArr != null) {
                        for (r in 0 until refsArr.length()) refs.add(refsArr.optString(r))
                    }
                    hostList.add(
                        ExecutionHost(
                            id = h.optString("id", h.optString("hostname")),
                            hostname = h.optString("hostname"),
                            currentRole = h.optString("current_role").takeIf { it.isNotBlank() },
                            state = h.optString("state").takeIf { it.isNotBlank() },
                            accountRefs = refs
                        )
                    )
                }
            }
            val autoSwitch = if (doc.has("auto_switch_enabled")) doc.optBoolean("auto_switch_enabled") else null
            val autoAvail = if (doc.has("auto_switch_available")) doc.optBoolean("auto_switch_available") else null
            hostStatus = NASHostStatus(hostList, autoSwitch, autoAvail)
        }

        if (servicesArr != null) {
            for (i in 0 until servicesArr.length()) {
                val svcObj = servicesArr.optJSONObject(i) ?: continue
                val name = svcObj.optString("service")
                val service = Service.fromRaw(name) ?: continue

                val ok = svcObj.optBoolean("ok", false)
                val stale = svcObj.optBoolean("stale", false)
                val fetchedAtSeconds = svcObj.optDouble("fetched_at", 0.0)
                val fetchedAt = if (fetchedAtSeconds > 0) Date((fetchedAtSeconds * 1000).toLong()) else null
                val accountDisplay = svcObj.optString("account_display").takeIf { it.isNotBlank() }

                val itemsArr = svcObj.optJSONArray("items")
                val windows = mutableListOf<UsageWindow>()
                var creditBalance: Double? = null
                var creditUnlimited = false
                var codexCreditsAvailable: Int? = null
                val codexExpirations = mutableListOf<Date>()
                var claudeLimitResetsCount: Int? = null
                var claudeLimitResetsExpiresAt: Date? = null

                if (itemsArr != null) {
                    for (j in 0 until itemsArr.length()) {
                        val item = itemsArr.optJSONObject(j) ?: continue
                        val rawWindow = item.optString("window", item.optString("name", "window_$j"))
                        val windowId = if (service == Service.CLAUDE && rawWindow == "weekly") {
                            // Mirrors the iPhone NAS parser: the Fable pool is matched by
                            // name (case-insensitive "fable"), the overall weekly pool by the
                            // exact general name ("전체"/"claude") rather than "first weekly
                            // item that isn't Fable", so other per-model pools are never
                            // mistaken for the overall limit.
                            val itemName = item.optString("name")
                            when {
                                itemName.contains("fable", ignoreCase = true) -> "fableWeekly"
                                itemName == "전체" || itemName.equals("claude", ignoreCase = true) -> "weekly"
                                else -> "weekly:$itemName"
                            }
                        } else {
                            rawWindow
                        }
                        val remaining = if (item.has("remaining_percent")) item.optDouble("remaining_percent") else null
                        val resetsAtSec = item.optDouble("resets_at", 0.0)
                        val resetsAt = if (resetsAtSec > 0) Date((resetsAtSec * 1000).toLong()) else null

                        windows.add(
                            UsageWindow(
                                id = windowId,
                                label = when (windowId) {
                                    "weekly" -> "주간"
                                    "fiveHour", "session" -> "세션"
                                    "fableWeekly" -> "페이블"
                                    else -> item.optString("name", windowId)
                                },
                                remainingPercent = remaining,
                                resetsAt = resetsAt
                            )
                        )

                        val credits = item.optJSONObject("credits")
                        if (credits != null) {
                            if (credits.has("balance")) creditBalance = credits.optDouble("balance")
                            if (credits.has("unlimited")) creditUnlimited = credits.optBoolean("unlimited")
                        }

                        val codexDetails = item.optJSONObject("codex_details")
                        if (codexDetails != null) {
                            if (codexDetails.has("reset_credits_available")) {
                                codexCreditsAvailable = codexDetails.optInt("reset_credits_available")
                            }
                            val expArr = codexDetails.optJSONArray("reset_credit_expirations")
                            if (expArr != null) {
                                for (k in 0 until expArr.length()) {
                                    val expSec = expArr.optDouble(k, 0.0)
                                    if (expSec > 0) codexExpirations.add(Date((expSec * 1000).toLong()))
                                }
                            }
                        }

                        val claudeDetails = item.optJSONObject("claude_details")
                        if (claudeDetails != null) {
                            val limitResets = claudeDetails.optJSONObject("limit_resets")
                            if (limitResets != null) {
                                if (limitResets.has("remaining_count")) {
                                    claudeLimitResetsCount = limitResets.optInt("remaining_count")
                                }
                                val expSec = limitResets.optDouble("expires_at", 0.0)
                                if (expSec > 0) claudeLimitResetsExpiresAt = Date((expSec * 1000).toLong())
                            }
                        }
                    }
                }

                var errReason: String? = null
                val err = svcObj.opt("error")
                if (err is JSONObject) {
                    errReason = err.optString("message", err.optString("code"))
                }

                servicesMap[service] = ServiceUsage(
                    service = service,
                    account = svcObj.optString("account_ref").takeIf { it.isNotBlank() },
                    accountDisplay = accountDisplay,
                    windows = windows,
                    creditBalance = creditBalance,
                    creditUnlimited = creditUnlimited,
                    fetchedAt = fetchedAt,
                    status = if (ok) "ok" else "error",
                    errorReason = errReason,
                    stale = stale,
                    codexResetCreditsAvailable = codexCreditsAvailable,
                    codexResetCreditExpirations = codexExpirations.sorted(),
                    claudeLimitResetsCount = claudeLimitResetsCount,
                    claudeLimitResetsExpiresAt = claudeLimitResetsExpiresAt,
                    nasHostStatus = if (service.isGemini) hostStatus else null
                )
            }
        }

        val genAtSec = doc.optDouble("generated_at", 0.0)
        val genAt = if (genAtSec > 0) Date((genAtSec * 1000).toLong()) else null

        return UsageSnapshot(
            services = servicesMap,
            generatedAt = genAt,
            nasHostStatus = hostStatus
        )
    }

    fun saveSnapshotCache(context: Context, doc: JSONObject, isV2: Boolean, lastKnown: Set<String>) {
        try {
            val wrapper = JSONObject()
            wrapper.put("cacheFormat", if (isV2) SNAPSHOT_V2_FORMAT else SNAPSHOT_LEGACY_FORMAT)
            wrapper.put("snapshot", doc)
            val lkArr = JSONArray()
            lastKnown.sorted().forEach { lkArr.put(it) }
            wrapper.put("lastKnown", lkArr)
            wrapper.put("baseURLOrigin", NASConfig.baseURLString)

            val bytes = wrapper.toString().toByteArray(Charsets.UTF_8)
            if (bytes.size <= MAX_SNAPSHOT_CACHE_BYTES) {
                val file = File(context.filesDir, "last-usage-nas-v1.json")
                val atomicFile = AtomicFile(file)
                var fos: FileOutputStream? = null
                try {
                    fos = atomicFile.startWrite()
                    fos.write(bytes)
                    atomicFile.finishWrite(fos)
                } catch (e: Exception) {
                    if (fos != null) atomicFile.failWrite(fos)
                }
            }
        } catch (_: Exception) {}
    }

    fun loadSnapshotCache(context: Context): Pair<UsageSnapshot, JSONObject>? {
        val file = File(context.filesDir, "last-usage-nas-v1.json")
        if (!file.exists()) return null
        return try {
            val atomicFile = AtomicFile(file)
            val bytes = atomicFile.readFully()
            if (bytes.size > MAX_SNAPSHOT_CACHE_BYTES) return null

            val root = JSONObject(String(bytes, Charsets.UTF_8))
            val origin = root.optString("baseURLOrigin")
            if (origin != NASConfig.baseURLString) return null

            val format = root.optString("cacheFormat", SNAPSHOT_LEGACY_FORMAT)
            val isV2 = format == SNAPSHOT_V2_FORMAT
            val snapDoc = root.optJSONObject("snapshot") ?: return null

            val lkSet = mutableSetOf<String>()
            val lkArr = root.optJSONArray("lastKnown")
            if (lkArr != null) {
                for (i in 0 until lkArr.length()) lkSet.add(lkArr.optString(i))
            }

            val parsed = parseSnapshot(snapDoc, isV2).markingLastKnown(lkSet).markingNASHostStatusCached()
            Pair(parsed, snapDoc)
        } catch (_: Exception) {
            null
        }
    }
}
