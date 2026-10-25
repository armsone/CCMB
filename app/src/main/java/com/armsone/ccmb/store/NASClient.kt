package com.armsone.ccmb.store

import android.webkit.CookieManager
import com.armsone.ccmb.model.NASConsumptionHistory
import com.armsone.ccmb.model.Service
import com.armsone.ccmb.model.UsageConsumptionPoint
import com.armsone.ccmb.model.UsageSnapshot
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.time.Instant
import java.util.Date
import java.util.UUID

object NASConfig {
    const val baseURLString = "https://hanstree.synology.me:5443"
    val baseURL: URL = URL(baseURLString)
    const val allowedHost = "hanstree.synology.me"
    const val allowedPort = 5443
}

sealed class NASFetchException(override val message: String) : Exception(message) {
    object InvalidAddress : NASFetchException("설정에서 NAS 주소를 다시 확인해 주세요. 올바른 https 주소가 아닙니다.")
    object NotAuthenticated : NASFetchException("NAS에 다시 로그인해 주세요. 로그인이 만료되었거나 아직 되어 있지 않습니다.")
    object Forbidden : NASFetchException("이 계정은 사용량 조회 권한이 없습니다. 권한이 있는 계정으로 다시 로그인해 주세요.")
    object NotFound : NASFetchException("NAS 앱을 최신 버전으로 업데이트한 뒤 다시 시도해 주세요. 요청한 항목을 NAS에서 찾을 수 없습니다.")
    object RateLimited : NASFetchException("새로고침 요청이 너무 자주 발생했습니다. 잠시 후 다시 시도해 주세요.")
    object Network : NASFetchException("네트워크 연결을 확인한 뒤 다시 시도해 주세요. NAS에 접속하지 못했습니다.")
    object Timeout : NASFetchException("NAS 응답이 오래 걸립니다. 잠시 후 다시 시도해 주세요.")
    object ServerUnavailable : NASFetchException("NAS 서비스가 잠시 응답하지 않습니다. 잠시 후 다시 시도해 주세요.")
    class ServerError(code: Int) : NASFetchException("잠시 후 다시 시도해 주세요. NAS 오류: HTTP $code")
    object UnreadableResponse : NASFetchException("NAS 앱을 최신 버전으로 업데이트한 뒤 다시 시도해 주세요. 응답 형식을 읽을 수 없습니다.")
}

enum class NASRefreshJobState {
    QUEUED, RUNNING, COMPLETED, FAILED, DEFERRED
}

enum class NASRefreshOutcome {
    COMPLETED, FAILED, DEFERRED, STILL_RUNNING, JOB_UNAVAILABLE
}

data class NASSnapshotFetchResult(
    val data: ByteArray,
    val isV2: Boolean,
    val refreshOutcome: NASRefreshOutcome?,
    val retryAfterSeconds: Double?
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is NASSnapshotFetchResult) return false
        return data.contentEquals(other.data) && isV2 == other.isV2 && refreshOutcome == other.refreshOutcome && retryAfterSeconds == other.retryAfterSeconds
    }

    override fun hashCode(): Int {
        var result = data.contentHashCode()
        result = 31 * result + isV2.hashCode()
        result = 31 * result + (refreshOutcome?.hashCode() ?: 0)
        result = 31 * result + (retryAfterSeconds?.hashCode() ?: 0)
        return result
    }
}

object NASClient {
    private const val SESSION_COOKIE_NAME = "hw_session"
    private const val REFRESH_WAIT_BUDGET_SECONDS = 25.0
    private const val MAX_RETRY_AFTER_SECONDS = 3600.0

    fun getSessionCookie(): String? {
        val cookies = CookieManager.getInstance().getCookie(NASConfig.baseURLString) ?: return null
        val items = cookies.split(";")
        for (item in items) {
            val parts = item.trim().split("=", limit = 2)
            if (parts.size == 2 && parts[0] == SESSION_COOKIE_NAME) {
                val value = parts[1]
                if (value.isNotEmpty()) return value
            }
        }
        return null
    }

    fun hasSessionCookie(): Boolean = getSessionCookie() != null

    suspend fun checkSession(): Boolean = withContext(Dispatchers.IO) {
        val cookie = getSessionCookie() ?: return@withContext false
        try {
            val url = URL("${NASConfig.baseURLString}/api/session")
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                instanceFollowRedirects = false
                connectTimeout = 10_000
                readTimeout = 10_000
                setRequestProperty("Cookie", "$SESSION_COOKIE_NAME=$cookie")
            }
            if (conn.responseCode in 200..299) {
                val text = conn.inputStream.bufferedReader().use { it.readText() }
                val json = JSONObject(text)
                return@withContext json.optBoolean("authenticated", false)
            }
            false
        } catch (_: Exception) {
            false
        }
    }

    private fun isSameOrigin(url: URL): Boolean {
        return url.protocol.equals("https", ignoreCase = true) &&
                url.host.equals(NASConfig.allowedHost, ignoreCase = true) &&
                (url.port == NASConfig.allowedPort || (url.port == -1 && NASConfig.allowedPort == 443))
    }

    private suspend fun requestHttp(
        method: String,
        urlString: String,
        bodyJson: String? = null,
        timeoutSeconds: Int = 30
    ): Pair<Int, ByteArray> = withContext(Dispatchers.IO) {
        val url = URL(urlString)
        if (!isSameOrigin(url)) {
            throw NASFetchException.InvalidAddress
        }
        val cookie = getSessionCookie() ?: throw NASFetchException.NotAuthenticated

        try {
            val conn = (url.openConnection() as HttpURLConnection).apply {
                this.requestMethod = method
                instanceFollowRedirects = false
                connectTimeout = timeoutSeconds * 1000
                readTimeout = timeoutSeconds * 1000
                setRequestProperty("Cookie", "$SESSION_COOKIE_NAME=$cookie")
                if (method == "POST") {
                    doOutput = true
                    setRequestProperty("Content-Type", "application/json")
                    setRequestProperty("Origin", NASConfig.baseURLString)
                }
            }

            if (method == "POST" && bodyJson != null) {
                conn.outputStream.use { os ->
                    os.write(bodyJson.toByteArray(Charsets.UTF_8))
                }
            }

            val code = conn.responseCode
            val stream: InputStream? = if (code in 200..299) conn.inputStream else conn.errorStream
            val bytes = stream?.use { it.readBytes() } ?: ByteArray(0)
            Pair(code, bytes)
        } catch (_: SocketTimeoutException) {
            // Raw IO failures surfaced as "timeout"/"Unable to resolve host" before;
            // map them so the visible refreshProblem is a real, readable message.
            throw NASFetchException.Timeout
        } catch (_: IOException) {
            throw NASFetchException.Network
        }
    }

    private fun classifyCode(code: Int): NASFetchException? = when (code) {
        in 200..299 -> null
        401 -> NASFetchException.NotAuthenticated
        403 -> NASFetchException.Forbidden
        404 -> NASFetchException.NotFound
        429 -> NASFetchException.RateLimited
        503 -> NASFetchException.ServerUnavailable
        else -> NASFetchException.ServerError(code)
    }

    suspend fun fetchSnapshot(refresh: Boolean): NASSnapshotFetchResult {
        val v2Url = "${NASConfig.baseURLString}/api/ccmb/v2/snapshot"
        val (firstCode, firstData) = requestHttp("GET", v2Url, timeoutSeconds = 30)

        if (firstCode == 404) {
            // Fallback to legacy only on explicit 404
            val legacyUrl = if (refresh) {
                "${NASConfig.baseURLString}/api/usage?refresh=1"
            } else {
                "${NASConfig.baseURLString}/api/usage"
            }
            val (legacyCode, legacyData) = requestHttp("GET", legacyUrl, timeoutSeconds = 30)
            classifyCode(legacyCode)?.let { throw it }
            return NASSnapshotFetchResult(
                data = legacyData,
                isV2 = false,
                refreshOutcome = null,
                retryAfterSeconds = null
            )
        }

        classifyCode(firstCode)?.let { throw it }

        if (!refresh) {
            return NASSnapshotFetchResult(
                data = firstData,
                isV2 = true,
                refreshOutcome = null,
                retryAfterSeconds = null
            )
        }

        // Manual refresh requested: POST /api/ccmb/v2/refresh
        val refreshPostUrl = "${NASConfig.baseURLString}/api/ccmb/v2/refresh"
        val (postCode, postData) = requestHttp("POST", refreshPostUrl, bodyJson = "{}", timeoutSeconds = 20)
        if (postCode != 202) {
            throw classifyCode(postCode) ?: NASFetchException.UnreadableResponse
        }

        val postJson = try {
            JSONObject(String(postData, Charsets.UTF_8))
        } catch (_: Exception) {
            throw NASFetchException.UnreadableResponse
        }
        val jobId = postJson.optString("job_id")
        if (!isSafeJobId(jobId)) {
            throw NASFetchException.UnreadableResponse
        }
        val retryAfter = postJson.optDouble("retry_after_seconds", 0.0)

        // Bounded polling for job
        val outcome = waitForJob(jobId)

        // Read final snapshot
        val (finalCode, finalData) = requestHttp("GET", v2Url, timeoutSeconds = 30)
        classifyCode(finalCode)?.let { throw it }

        return NASSnapshotFetchResult(
            data = finalData,
            isV2 = true,
            refreshOutcome = outcome,
            retryAfterSeconds = if (retryAfter in 0.0..MAX_RETRY_AFTER_SECONDS) retryAfter else null
        )
    }

    private fun isSafeJobId(jobId: String): Boolean {
        if (jobId.length != 36) return false
        return try {
            val uuid = UUID.fromString(jobId)
            uuid.toString() == jobId.lowercase()
        } catch (_: Exception) {
            false
        }
    }

    private suspend fun waitForJob(jobId: String): NASRefreshOutcome {
        val jobUrl = "${NASConfig.baseURLString}/api/ccmb/v2/refresh/$jobId"
        val startTime = System.currentTimeMillis()
        var delayMs = 1000L

        while (true) {
            val elapsedSeconds = (System.currentTimeMillis() - startTime) / 1000.0
            val remainingSeconds = REFRESH_WAIT_BUDGET_SECONDS - elapsedSeconds
            if (remainingSeconds <= 0) {
                return NASRefreshOutcome.STILL_RUNNING
            }

            val timeout = minOf(10, remainingSeconds.toInt().coerceAtLeast(1))
            // Transient transport trouble while polling: the job keeps running on the NAS,
            // so report STILL_RUNNING. Auth/origin failures must propagate (no silent fallback).
            val (code, data) = try {
                requestHttp("GET", jobUrl, timeoutSeconds = timeout)
            } catch (_: NASFetchException.Timeout) {
                return NASRefreshOutcome.STILL_RUNNING
            } catch (_: NASFetchException.Network) {
                return NASRefreshOutcome.STILL_RUNNING
            }

            if (code == 404) return NASRefreshOutcome.JOB_UNAVAILABLE
            classifyCode(code)?.let { throw it }

            val json = try {
                JSONObject(String(data, Charsets.UTF_8))
            } catch (_: Exception) {
                throw NASFetchException.UnreadableResponse
            }
            val stateStr = json.optString("state").lowercase()
            when (stateStr) {
                "completed" -> return NASRefreshOutcome.COMPLETED
                "failed" -> return NASRefreshOutcome.FAILED
                "deferred" -> return NASRefreshOutcome.DEFERRED
                "queued", "running" -> {
                    val timeLeft = (REFRESH_WAIT_BUDGET_SECONDS - ((System.currentTimeMillis() - startTime) / 1000.0))
                    if (timeLeft <= 0) return NASRefreshOutcome.STILL_RUNNING
                    val waitTime = minOf(delayMs, (timeLeft * 1000).toLong())
                    delay(waitTime)
                    delayMs = minOf(delayMs * 2, 4000L)
                }
                else -> return NASRefreshOutcome.STILL_RUNNING
            }
        }
    }

    suspend fun fetchStoredOnlineRelay(): ByteArray? {
        val url = "${NASConfig.baseURLString}/api/ccmb/files?name=CCMB-gemini-online-v1.json"
        return try {
            val (code, data) = requestHttp("GET", url, timeoutSeconds = 15)
            if (code == 200 && data.size <= 8192) data else null
        } catch (_: Exception) {
            null
        }
    }

    suspend fun fetchStoredConsumptionHistory(): NASConsumptionHistory? {
        // Try v3 -> v2 -> v1
        fetchHistoryFile("CCMB-nas-consumption-history-v3.json", 262144)?.let { data ->
            try {
                return parseHistoryV3(data)
            } catch (_: Exception) {}
        }
        fetchHistoryFile("CCMB-nas-consumption-history-v2.json", 524288)?.let { data ->
            try {
                return parseHistoryV2(data)
            } catch (_: Exception) {}
        }
        fetchHistoryFile("CCMB-nas-consumption-history-v1.json", 32768)?.let { data ->
            try {
                return parseHistoryV1(data)
            } catch (_: Exception) {}
        }
        return null
    }

    private suspend fun fetchHistoryFile(fileName: String, maxBytes: Int): ByteArray? {
        val url = "${NASConfig.baseURLString}/api/ccmb/files?name=$fileName"
        return try {
            val (code, data) = requestHttp("GET", url, timeoutSeconds = 15)
            if (code == 200 && data.size <= maxBytes) data else null
        } catch (_: Exception) {
            null
        }
    }

    fun parseHistoryV3(data: ByteArray): NASConsumptionHistory {
        val root = JSONObject(String(data, Charsets.UTF_8))
        val genAt = root.optLong("generatedAt", 0L).let { if (it > 0) Date(it) else null }
        val seriesObj = root.optJSONObject("series") ?: JSONObject()

        fun parseSeries(name: String): List<UsageConsumptionPoint> {
            val s = seriesObj.optJSONObject(name) ?: return emptyList()
            val pointsArr = s.optJSONArray("points") ?: return emptyList()
            val segmentsArr = s.optJSONArray("segments")
            val segments = mutableListOf<String?>()
            if (segmentsArr != null) {
                for (i in 0 until segmentsArr.length()) {
                    segments.add(segmentsArr.optString(i))
                }
            }
            val list = mutableListOf<UsageConsumptionPoint>()
            for (i in 0 until pointsArr.length()) {
                val p = pointsArr.optJSONArray(i) ?: continue
                val atMs = p.optLong(0)
                val consumed = p.optDouble(1, 0.0)
                val segIdx = p.optInt(2, -1)
                val segId = if (segIdx in 0 until segments.size) segments[segIdx] else null
                list.add(UsageConsumptionPoint(at = Date(atMs), amount = consumed, segmentId = segId))
            }
            return list
        }

        return NASConsumptionHistory(
            schemaVersion = 3,
            source = root.optString("source", "nas"),
            intervalSeconds = 180,
            slotCount = 40,
            generatedAt = genAt,
            windowSeconds = root.optDouble("windowSeconds", 86400.0),
            gapSeconds = root.optDouble("gapSeconds", 900.0),
            codex = parseSeries("codex"),
            codexCredits = parseSeries("codexCredits"),
            claude = parseSeries("claude"),
            claudeFable = parseSeries("claudeFable"),
            gemini = parseSeries("gemini"),
            gemini2 = parseSeries("gemini2"),
            gemini3 = parseSeries("gemini3")
        )
    }

    fun parseHistoryV2(data: ByteArray): NASConsumptionHistory {
        val root = JSONObject(String(data, Charsets.UTF_8))
        val genAt = root.optLong("generatedAt", 0L).let { if (it > 0) Date(it) else null }
        val seriesObj = root.optJSONObject("series") ?: JSONObject()

        fun parseSeries(name: String): List<UsageConsumptionPoint> {
            val s = seriesObj.optJSONObject(name) ?: return emptyList()
            val pointsArr = s.optJSONArray("points") ?: return emptyList()
            val list = mutableListOf<UsageConsumptionPoint>()
            for (i in 0 until pointsArr.length()) {
                val p = pointsArr.optJSONObject(i) ?: continue
                val atMs = p.optLong("at")
                val consumed = p.optDouble("consumed", 0.0)
                val segId = p.optString("segmentId").takeIf { it.isNotBlank() }
                list.add(UsageConsumptionPoint(at = Date(atMs), amount = consumed, segmentId = segId))
            }
            return list
        }

        return NASConsumptionHistory(
            schemaVersion = 2,
            source = root.optString("source", "nas"),
            intervalSeconds = 180,
            slotCount = 40,
            generatedAt = genAt,
            codex = parseSeries("codex"),
            codexCredits = parseSeries("codexCredits"),
            claude = parseSeries("claude"),
            claudeFable = parseSeries("claudeFable"),
            gemini = parseSeries("gemini"),
            gemini2 = parseSeries("gemini2"),
            gemini3 = parseSeries("gemini3")
        )
    }

    fun parseHistoryV1(data: ByteArray): NASConsumptionHistory {
        val root = JSONObject(String(data, Charsets.UTF_8))
        val colAt = root.optString("collectedAt").takeIf { it.isNotBlank() }?.let {
            try { Date.from(Instant.parse(it)) } catch (_: Exception) { null }
        }
        val histObj = root.optJSONObject("consumptionHistory") ?: JSONObject()

        fun parseSeries(name: String): List<UsageConsumptionPoint> {
            val arr = histObj.optJSONArray(name) ?: return emptyList()
            val list = mutableListOf<UsageConsumptionPoint>()
            for (i in 0 until arr.length()) {
                val p = arr.optJSONObject(i) ?: continue
                val atStr = p.optString("at")
                val at = try { Date.from(Instant.parse(atStr)) } catch (_: Exception) { continue }
                val amount = p.optDouble("amount", 0.0)
                list.add(UsageConsumptionPoint(at = at, amount = amount))
            }
            return list
        }

        return NASConsumptionHistory(
            schemaVersion = 1,
            source = root.optString("source", "nas"),
            intervalSeconds = root.optInt("intervalSeconds", 180),
            slotCount = root.optInt("slotCount", 40),
            collectedAt = colAt,
            codex = parseSeries("codex"),
            codexCredits = parseSeries("codexCredits"),
            claude = parseSeries("claude"),
            claudeFable = parseSeries("claudeFable"),
            gemini = parseSeries("gemini")
        )
    }
}
