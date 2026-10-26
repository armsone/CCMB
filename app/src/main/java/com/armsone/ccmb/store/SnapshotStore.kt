package com.armsone.ccmb.store

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.AtomicFile
import com.armsone.ccmb.model.ModelWeeklyLimit
import com.armsone.ccmb.model.NASConsumptionHistory
import com.armsone.ccmb.model.PreferredSource
import com.armsone.ccmb.model.Service
import com.armsone.ccmb.model.ServiceUsage
import com.armsone.ccmb.model.SnapshotOrigin
import com.armsone.ccmb.model.UsageConsumptionPoint
import com.armsone.ccmb.model.UsageSnapshot
import com.armsone.ccmb.model.UsageWindow
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.time.Instant
import java.util.Date

sealed class LoadState {
    object Empty : LoadState()
    object Loading : LoadState()
    data class Loaded(val snapshot: UsageSnapshot) : LoadState()
    data class Failed(val message: String) : LoadState()
}

class SnapshotStore(
    private val context: Context,
    private val scope: CoroutineScope
) {
    private val _state = MutableStateFlow<LoadState>(LoadState.Empty)
    val state: StateFlow<LoadState> = _state.asStateFlow()

    private val _displayedSource = MutableStateFlow(PreferredSource.NAS)
    val displayedSource: StateFlow<PreferredSource> = _displayedSource.asStateFlow()

    private val _origin = MutableStateFlow(SnapshotOrigin.NAS)
    val origin: StateFlow<SnapshotOrigin> = _origin.asStateFlow()

    private val _isNASLoginPresented = MutableStateFlow(false)
    val isNASLoginPresented: StateFlow<Boolean> = _isNASLoginPresented.asStateFlow()

    private val _nasNeedsLogin = MutableStateFlow(false)
    val nasNeedsLogin: StateFlow<Boolean> = _nasNeedsLogin.asStateFlow()

    private var hasAutoPromptedForEpisode = false

    private val _nasConnecting = MutableStateFlow(false)
    val nasConnecting: StateFlow<Boolean> = _nasConnecting.asStateFlow()

    private val _nasConnectError = MutableStateFlow<String?>(null)
    val nasConnectError: StateFlow<String?> = _nasConnectError.asStateFlow()

    private val _refreshProblem = MutableStateFlow<String?>(null)
    val refreshProblem: StateFlow<String?> = _refreshProblem.asStateFlow()

    private val _nextAutomaticRefreshAt = MutableStateFlow<Date?>(null)
    val nextAutomaticRefreshAt: StateFlow<Date?> = _nextAutomaticRefreshAt.asStateFlow()

    private val _nasRefreshBusy = MutableStateFlow(false)
    val nasRefreshBusy: StateFlow<Boolean> = _nasRefreshBusy.asStateFlow()

    private val _sourceFileName = MutableStateFlow<String?>(null)
    val sourceFileName: StateFlow<String?> = _sourceFileName.asStateFlow()

    var generation = 0
        private set

    private var autoRefreshJob: Job? = null
    private var nasRefreshJob: Job? = null
    private var nasRefreshJobGeneration = -1
    private var nasRefreshToken = 0
    private var didLoadOnLaunch = false
    private var isForeground = true
    private var previousCacheDoc: JSONObject? = null

    companion object {
        const val NAS_INTERVAL_SECONDS = 180L
        // NAS job still running after the manual wait budget: re-read the snapshot soon (GET only).
        const val STILL_RUNNING_RECHECK_SECONDS = 20L
        const val PREFS_NAME = "ccmb_prefs"
        const val PREFS_PREFERRED_SOURCE = "preferred_source"
        const val PREFS_PICKED_URI = "picked_snapshot_uri"
        const val PREFS_PICKED_FILE_NAME = "picked_snapshot_file_name"
    }

    fun loadOnLaunch() {
        if (didLoadOnLaunch) return
        didLoadOnLaunch = true

        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val prefSource = prefs.getString(PREFS_PREFERRED_SOURCE, "nas")

        if (prefSource == "file") {
            _nasNeedsLogin.value = false
            _isNASLoginPresented.value = false
            hasAutoPromptedForEpisode = false
            _displayedSource.value = PreferredSource.FILE
            _sourceFileName.value = prefs.getString(PREFS_PICKED_FILE_NAME, null)

            val cached = loadFileSnapshotCache()
            if (cached != null) {
                _state.value = LoadState.Loaded(cached)
                _origin.value = SnapshotOrigin.SAVED_COPY
            }

            scheduleAutomaticRefresh()
            refreshFromPickedFile()
            return
        }

        _displayedSource.value = PreferredSource.NAS

        // Load cached snapshot if available
        val cached = NASCacheCodec.loadSnapshotCache(context)
        if (cached != null) {
            val (snapshot, doc) = cached
            previousCacheDoc = doc
            _state.value = LoadState.Loaded(snapshot)
            _origin.value = SnapshotOrigin.SAVED_COPY
        }

        scheduleAutomaticRefresh()
        refresh(isAutomatic = true)
    }

    fun requestNASLogin() {
        _isNASLoginPresented.value = true
    }

    fun dismissNASLogin() {
        _isNASLoginPresented.value = false
    }

    fun connectNAS() {
        _isNASLoginPresented.value = false
        _nasNeedsLogin.value = false
        hasAutoPromptedForEpisode = false
        _nasConnectError.value = null
        _refreshProblem.value = null
        generation++
        _displayedSource.value = PreferredSource.NAS
        _origin.value = SnapshotOrigin.NAS
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putString(PREFS_PREFERRED_SOURCE, "nas").apply()
        // Fast read of stored snapshot on login without triggering collection wait
        refresh(isAutomatic = true)
    }

    fun useNAS() {
        generation++
        _nasNeedsLogin.value = false
        hasAutoPromptedForEpisode = false
        _displayedSource.value = PreferredSource.NAS
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putString(PREFS_PREFERRED_SOURCE, "nas").apply()

        val cached = NASCacheCodec.loadSnapshotCache(context)
        if (cached != null) {
            val (snapshot, doc) = cached
            previousCacheDoc = doc
            _state.value = LoadState.Loaded(snapshot)
            _origin.value = SnapshotOrigin.SAVED_COPY
        } else {
            _state.value = LoadState.Empty
        }
        _refreshProblem.value = null
        refresh(isAutomatic = false)
    }

    fun resumeAutomaticRefresh() {
        isForeground = true
        scheduleAutomaticRefresh()
    }

    fun pauseAutomaticRefresh() {
        isForeground = false
        autoRefreshJob?.cancel()
        autoRefreshJob = null
        _nextAutomaticRefreshAt.value = null
    }

    fun scheduleAutomaticRefresh(delaySeconds: Long = NAS_INTERVAL_SECONDS) {
        autoRefreshJob?.cancel()
        if (!isForeground) return

        val nextDate = Date(System.currentTimeMillis() + (delaySeconds * 1000))
        _nextAutomaticRefreshAt.value = nextDate

        autoRefreshJob = scope.launch {
            delay(delaySeconds * 1000)
            if (isActive && isForeground) {
                refresh(isAutomatic = true)
            }
        }
    }

    fun refresh(isAutomatic: Boolean = false) {
        // Always re-arm the 180s timer: a manual tap resets it, and an automatic tick
        // must schedule the next one (previously the automatic path never re-armed).
        scheduleAutomaticRefresh()

        when (_displayedSource.value) {
            PreferredSource.NAS -> refreshFromNAS(isAutomatic)
            PreferredSource.FILE -> refreshFromPickedFile()
            PreferredSource.CLOUD -> {
                // CloudKit is explicitly marked pending web services / auth
                _refreshProblem.value = "CloudKit 동기화는 웹 서비스 및 계정 설정 구성 보류 상태입니다."
            }
        }
    }

    private fun refreshFromNAS(isAutomatic: Boolean) {
        val currentGen = generation
        // One NAS request per generation at a time: an automatic tick must not race a
        // manual job, otherwise the first finisher would clear the other's busy flags.
        if (nasRefreshJob?.isActive == true && nasRefreshJobGeneration == currentGen) return

        val hasExistingSnapshot = _state.value is LoadState.Loaded

        if (!hasExistingSnapshot) {
            _state.value = LoadState.Loading
        }
        _nasConnecting.value = true
        _nasConnectError.value = null
        if (!isAutomatic) {
            // User tapped refresh: busy from the request until the job outcome is known.
            _nasRefreshBusy.value = true
        }

        val myToken = ++nasRefreshToken
        nasRefreshJobGeneration = currentGen
        nasRefreshJob = scope.launch {
            var serverStillCollecting = false
            try {
                val fetchResult = withContext(Dispatchers.IO) {
                    NASClient.fetchSnapshot(refresh = !isAutomatic)
                }

                if (currentGen != generation) return@launch

                val sanitized = NASCacheCodec.sanitizeDocument(fetchResult.data, fetchResult.isV2)
                    ?: throw NASFetchException.UnreadableResponse

                val (mergedDoc, lastKnown) = NASCacheCodec.mergeLastKnown(
                    incoming = sanitized,
                    previous = previousCacheDoc,
                    isV2 = fetchResult.isV2
                )
                previousCacheDoc = mergedDoc

                withContext(Dispatchers.IO) {
                    NASCacheCodec.saveSnapshotCache(context, mergedDoc, fetchResult.isV2, lastKnown)
                }

                var snapshot = NASCacheCodec.parseSnapshot(mergedDoc, fetchResult.isV2)
                    .markingLastKnown(lastKnown)

                if (fetchResult.refreshOutcome == NASRefreshOutcome.STILL_RUNNING) {
                    snapshot.collectionBusy = true
                    serverStillCollecting = true
                }

                if (currentGen != generation || myToken != nasRefreshToken) return@launch

                _state.value = LoadState.Loaded(snapshot)
                _origin.value = SnapshotOrigin.NAS
                _refreshProblem.value = describeRefreshOutcome(
                    fetchResult.refreshOutcome,
                    fetchResult.retryAfterSeconds
                )
                _nasNeedsLogin.value = false
                hasAutoPromptedForEpisode = false

                // Try fetching Gemini online relay and NAS consumption history asynchronously
                val onlineRelayData = withContext(Dispatchers.IO) { NASClient.fetchStoredOnlineRelay() }
                if (onlineRelayData != null) {
                    snapshot = applyGeminiOnline(snapshot, onlineRelayData)
                }

                val historyData = withContext(Dispatchers.IO) { NASClient.fetchStoredConsumptionHistory() }
                if (historyData != null) {
                    snapshot = snapshot.copy(consumptionHistory = historyData)
                }

                // Re-check after the cache/relay/history awaits: a source switch or reconnect
                // may have bumped the generation meanwhile, and a stale result must not publish.
                if (currentGen != generation || myToken != nasRefreshToken) return@launch

                _state.value = LoadState.Loaded(snapshot)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (currentGen != generation || myToken != nasRefreshToken) return@launch
                val errMsg = e.message ?: "데이터를 불러오지 못했습니다."

                if (e is NASFetchException.NotAuthenticated) {
                    _nasNeedsLogin.value = true
                    if (!hasAutoPromptedForEpisode) {
                        hasAutoPromptedForEpisode = true
                        _isNASLoginPresented.value = true
                    }
                }

                if (hasExistingSnapshot) {
                    _refreshProblem.value = errMsg
                } else {
                    _state.value = LoadState.Failed(errMsg)
                    _nasConnectError.value = errMsg
                }
            } finally {
                // Only the most recent request owns the flags; a superseded one must not
                // clear the busy state of the request that replaced it.
                if (myToken == nasRefreshToken) {
                    _nasConnecting.value = false
                    _nasRefreshBusy.value = false
                    if (serverStillCollecting && currentGen == generation) {
                        scheduleAutomaticRefresh(delaySeconds = STILL_RUNNING_RECHECK_SECONDS)
                    }
                }
            }
        }
    }

    private fun describeRefreshOutcome(outcome: NASRefreshOutcome?, retryAfterSeconds: Double?): String? {
        val lastStored = "표시된 값은 NAS에 저장된 마지막 스냅샷입니다."
        return when (outcome) {
            null, NASRefreshOutcome.COMPLETED, NASRefreshOutcome.STILL_RUNNING -> null
            NASRefreshOutcome.FAILED -> "NAS 수집 작업이 실패했습니다. $lastStored"
            NASRefreshOutcome.DEFERRED -> {
                val secs = retryAfterSeconds?.takeIf { it > 0 }?.toInt()
                if (secs != null) {
                    "NAS가 수집 요청을 보류했습니다. 약 ${secs}초 후 다시 시도해 주세요. $lastStored"
                } else {
                    "NAS가 수집 요청을 보류했습니다. 잠시 후 다시 시도해 주세요. $lastStored"
                }
            }
            NASRefreshOutcome.JOB_UNAVAILABLE -> "NAS가 새로고침 작업 상태를 알려주지 않았습니다. $lastStored"
        }
    }

    private fun applyGeminiOnline(snapshot: UsageSnapshot, data: ByteArray): UsageSnapshot {
        return try {
            val root = JSONObject(String(data, Charsets.UTF_8))
            val geminiObj = root.optJSONObject("gemini")?.optJSONObject("online") ?: return snapshot
            val fiveHour = if (geminiObj.has("fiveHourRemainingPercent")) geminiObj.optDouble("fiveHourRemainingPercent") else null
            val weekly = if (geminiObj.has("weeklyRemainingPercent")) geminiObj.optDouble("weeklyRemainingPercent") else null
            val fetchedAtStr = geminiObj.optString("fetchedAt")
            val fetchedAt = try { Date.from(Instant.parse(fetchedAtStr)) } catch (_: Exception) { null }

            val updatedServices = snapshot.services.toMutableMap()
            val existingGemini = updatedServices[Service.GEMINI]
            if (existingGemini != null) {
                val newWindows = existingGemini.windows.toMutableList()
                if (fiveHour != null) {
                    newWindows.removeAll { it.id == "onlineFiveHour" }
                    newWindows.add(UsageWindow("onlineFiveHour", "온라인 세션", remainingPercent = fiveHour, fetchedAt = fetchedAt))
                }
                if (weekly != null) {
                    newWindows.removeAll { it.id == "onlineWeekly" }
                    newWindows.add(UsageWindow("onlineWeekly", "온라인 주간", remainingPercent = weekly, fetchedAt = fetchedAt))
                }
                updatedServices[Service.GEMINI] = existingGemini.copy(windows = newWindows)
            }
            snapshot.copy(services = updatedServices)
        } catch (_: Exception) {
            snapshot
        }
    }

    fun importPickedFile(uri: Uri, fileName: String?) {
        scope.launch {
            try {
                // Take persistable URI permission if allowed by provider
                try {
                    context.contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                } catch (_: SecurityException) {}

                val bytes = withContext(Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.use { stream ->
                        stream.readBytes()
                    }
                } ?: throw Exception("파일을 열 수 없습니다.")

                if (bytes.size > 1024 * 1024) throw Exception("파일 크기가 너무 큽니다 (최대 1MB)")

                val snapshot = parseSnapshotBytes(bytes)

                // Store selected URI + chosen FILE source in private prefs ONLY after parse success
                val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                prefs.edit()
                    .putString(PREFS_PREFERRED_SOURCE, "file")
                    .putString(PREFS_PICKED_URI, uri.toString())
                    .putString(PREFS_PICKED_FILE_NAME, fileName)
                    .apply()

                withContext(Dispatchers.IO) {
                    saveFileSnapshotCache(bytes)
                }

                generation++
                _displayedSource.value = PreferredSource.FILE
                _nasNeedsLogin.value = false
                _isNASLoginPresented.value = false
                hasAutoPromptedForEpisode = false
                _origin.value = SnapshotOrigin.PICKED_FILE
                _sourceFileName.value = fileName
                _state.value = LoadState.Loaded(snapshot)
                _refreshProblem.value = null
            } catch (e: Exception) {
                _refreshProblem.value = "파일을 읽을 수 없습니다: ${e.message}"
            }
        }
    }

    private fun refreshFromPickedFile() {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val uriString = prefs.getString(PREFS_PICKED_URI, null)
        if (uriString == null) {
            _refreshProblem.value = "선택된 파일이 없습니다. 로컬 파일을 다시 선택해 주세요."
            return
        }

        val currentGen = generation
        val hasExistingSnapshot = _state.value is LoadState.Loaded

        if (!hasExistingSnapshot) {
            _state.value = LoadState.Loading
        }

        scope.launch {
            try {
                val uri = Uri.parse(uriString)
                val bytes = withContext(Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.use { stream ->
                        stream.readBytes()
                    }
                } ?: throw Exception("파일을 열 수 없습니다.")

                if (bytes.size > 1024 * 1024) throw Exception("파일 크기가 너무 큽니다 (최대 1MB)")
                if (currentGen != generation) return@launch

                val snapshot = parseSnapshotBytes(bytes)

                withContext(Dispatchers.IO) {
                    saveFileSnapshotCache(bytes)
                }

                _state.value = LoadState.Loaded(snapshot)
                _origin.value = SnapshotOrigin.PICKED_FILE
                _refreshProblem.value = null
            } catch (e: Exception) {
                if (currentGen != generation) return@launch
                val errMsg = "파일을 다시 선택해 주세요. 선택한 파일을 읽을 수 없습니다."
                if (hasExistingSnapshot) {
                    _refreshProblem.value = errMsg
                } else {
                    _state.value = LoadState.Failed(errMsg)
                }
            }
        }
    }

    fun setCatalogSnapshot(snapshot: UsageSnapshot) {
        _state.value = LoadState.Loaded(snapshot)
        _origin.value = SnapshotOrigin.SAVED_COPY
        _refreshProblem.value = null
    }

    private fun parseSnapshotBytes(bytes: ByteArray): UsageSnapshot {
        val root = JSONObject(String(bytes, Charsets.UTF_8))
        return if (root.optInt("schemaVersion") == 1) {
            parseMacUsageV1(root)
        } else if (root.optInt("schema_version") == 2) {
            NASCacheCodec.parseSnapshot(root, isV2 = true)
        } else if (root.has("report")) {
            NASCacheCodec.parseSnapshot(root, isV2 = false)
        } else {
            throw Exception("지원하지 않는 스키마 버전입니다. usage-v1.json 또는 NAS 스냅샷 파일을 선택해 주세요.")
        }
    }

    private fun parseMacUsageV1(root: JSONObject): UsageSnapshot {
        val fetchedAt = parseIsoDate(root.optString("fetchedAt"))
        val publishedAt = parseIsoDate(root.optString("publishedAt"))
        val appVersion = root.optString("appVersion").takeIf { it.isNotBlank() }

        val services = mutableMapOf<Service, ServiceUsage>()

        // 1. Codex
        val codexObj = root.optJSONObject("codex") ?: root
        val codexStatus = codexObj.optString("status").takeIf { it.isNotBlank() }
        val codexSessionRemaining = optNonBoolDouble(codexObj, "sessionRemainingPercent")
            ?: optNonBoolDouble(codexObj, "fiveHourRemainingPercent")
        val codexSessionResetsAt = parseIsoDate(
            codexObj.optString("sessionResetsAt").ifEmpty { codexObj.optString("fiveHourResetsAt") }
        )
        val codexWeeklyRemaining = optNonBoolDouble(codexObj, "weeklyRemainingPercent")
        val codexWeeklyResetsAt = parseIsoDate(
            codexObj.optString(if (root.has("codex")) "weeklyResetsAt" else "resetsAt")
        )
        val codexCredit = optNonBoolDouble(codexObj, "creditBalance")
        val codexAccount = codexObj.optString("account").takeIf { it.isNotBlank() }
        val codexFetchedAt = parseIsoDate(codexObj.optString("fetchedAt")) ?: fetchedAt

        services[Service.CODEX] = ServiceUsage(
            service = Service.CODEX,
            status = codexStatus ?: "ok",
            windows = listOf(
                UsageWindow(
                    id = "session",
                    label = "세션",
                    remainingPercent = codexSessionRemaining,
                    resetsAt = codexSessionResetsAt,
                    unavailabilityNote = if (codexSessionRemaining == null && codexSessionResetsAt == null) "Mac 데이터에서 제공되지 않음" else null
                ),
                UsageWindow(
                    id = "weekly",
                    label = "주간",
                    remainingPercent = codexWeeklyRemaining,
                    resetsAt = codexWeeklyResetsAt
                )
            ),
            creditBalance = codexCredit,
            creditLabel = "크레딧 잔액",
            account = codexAccount,
            accountDisplay = codexAccount,
            fetchedAt = codexFetchedAt
        )

        // 2. Claude
        val claudeObj = root.optJSONObject("claude")
        if (claudeObj != null) {
            val claudeStatus = claudeObj.optString("status").takeIf { it.isNotBlank() }
            val fiveHourRemaining = optNonBoolDouble(claudeObj, "fiveHourRemainingPercent")
            val fiveHourResetsAt = parseIsoDate(claudeObj.optString("fiveHourResetsAt"))
            val weeklyRemaining = optNonBoolDouble(claudeObj, "weeklyRemainingPercent")
            val weeklyResetsAt = parseIsoDate(claudeObj.optString("weeklyResetsAt"))

            val modelLimits = mutableListOf<ModelWeeklyLimit>()
            val limitsArr = claudeObj.optJSONArray("modelWeeklyLimits")
            if (limitsArr != null) {
                for (i in 0 until limitsArr.length()) {
                    val item = limitsArr.optJSONObject(i) ?: continue
                    val modelName = item.optString("model")
                    if (modelName.isNotBlank()) {
                        modelLimits.add(
                            ModelWeeklyLimit(
                                id = modelName,
                                modelName = modelName,
                                remainingPercent = optNonBoolDouble(item, "remainingPercent"),
                                resetsAt = parseIsoDate(item.optString("resetsAt"))
                            )
                        )
                    }
                }
            }

            val fableLimit = modelLimits.firstOrNull { it.modelName.contains("fable", ignoreCase = true) }
            val claudeAccountObj = claudeObj.optJSONObject("account")
            val claudeEmail = claudeAccountObj?.optString("email")?.takeIf { it.isNotBlank() }
                ?: claudeObj.optString("account").takeIf { it.isNotBlank() }
            val claudeOrg = claudeAccountObj?.optString("organizationName")?.takeIf { it.isNotBlank() }
            val claudeModel = claudeObj.optString("model").takeIf { it.isNotBlank() }
            val claudeFetchedAt = parseIsoDate(claudeObj.optString("fetchedAt")) ?: fetchedAt

            services[Service.CLAUDE] = ServiceUsage(
                service = Service.CLAUDE,
                status = claudeStatus ?: "ok",
                windows = listOf(
                    UsageWindow(
                        id = "fableWeekly",
                        label = "Fable 주간",
                        remainingPercent = fableLimit?.remainingPercent,
                        resetsAt = fableLimit?.resetsAt,
                        unavailabilityNote = if (fableLimit == null) "Mac 데이터에서 제공되지 않음" else null
                    ),
                    UsageWindow(
                        id = "fiveHour",
                        label = "5시간 세션",
                        remainingPercent = fiveHourRemaining,
                        resetsAt = fiveHourResetsAt
                    ),
                    UsageWindow(
                        id = "weekly",
                        label = "전체 주간",
                        remainingPercent = weeklyRemaining,
                        resetsAt = weeklyResetsAt
                    )
                ),
                account = claudeEmail,
                accountDisplay = claudeEmail,
                organizationName = claudeOrg,
                model = claudeModel,
                modelWeeklyLimits = modelLimits,
                fetchedAt = claudeFetchedAt
            )
        }

        // 3. Gemini
        fun parseGeminiObj(obj: JSONObject?, svc: Service): ServiceUsage? {
            if (obj == null) return null
            val status = obj.optString("status").takeIf { it.isNotBlank() }
            val fiveHourRemaining = optNonBoolDouble(obj, "fiveHourRemainingPercent")
            val fiveHourResetsAt = parseIsoDate(obj.optString("fiveHourResetsAt"))
            val weeklyRemaining = optNonBoolDouble(obj, "weeklyRemainingPercent")
            val weeklyResetsAt = parseIsoDate(obj.optString("weeklyResetsAt"))
            val planTitle = obj.optString("planTitle").takeIf { it.isNotBlank() }
            val fetched = parseIsoDate(obj.optString("fetchedAt")) ?: fetchedAt

            return ServiceUsage(
                service = svc,
                status = status ?: "ok",
                windows = listOf(
                    UsageWindow(
                        id = "cliFiveHour",
                        label = "C세션",
                        remainingPercent = fiveHourRemaining,
                        resetsAt = fiveHourResetsAt,
                        resetText = if (fiveHourResetsAt == null && (fiveHourRemaining ?: 0.0) >= 100.0) "사용 시작 후 5시간" else null,
                        unavailabilityNote = if (fiveHourRemaining == null) "미제공" else null
                    ),
                    UsageWindow(
                        id = "cliWeekly",
                        label = "C주간",
                        remainingPercent = weeklyRemaining,
                        resetsAt = weeklyResetsAt,
                        unavailabilityNote = if (weeklyRemaining == null) "미제공" else null
                    )
                ),
                planTitle = planTitle,
                fetchedAt = fetched
            )
        }

        val gemini1 = parseGeminiObj(root.optJSONObject("gemini"), Service.GEMINI)
        if (gemini1 != null) services[Service.GEMINI] = gemini1

        val gemini2 = parseGeminiObj(root.optJSONObject("gemini2"), Service.GEMINI2)
        if (gemini2 != null) services[Service.GEMINI2] = gemini2

        val gemini3 = parseGeminiObj(root.optJSONObject("gemini3"), Service.GEMINI3)
        if (gemini3 != null) services[Service.GEMINI3] = gemini3

        // Consumption History
        var history: NASConsumptionHistory? = null
        val histObj = root.optJSONObject("consumptionHistory")
        if (histObj != null) {
            fun parsePoints(key: String): List<UsageConsumptionPoint> {
                val arr = histObj.optJSONArray(key) ?: return emptyList()
                val list = mutableListOf<UsageConsumptionPoint>()
                for (i in 0 until arr.length()) {
                    val item = arr.optJSONObject(i) ?: continue
                    val at = parseIsoDate(item.optString("at")) ?: continue
                    val amt = optNonBoolDouble(item, "amount") ?: 0.0
                    list.add(UsageConsumptionPoint(at = at, amount = Math.max(0.0, amt)))
                }
                return list
            }

            history = NASConsumptionHistory(
                schemaVersion = 1,
                source = "mac-file",
                intervalSeconds = 1800,
                slotCount = histObj.optInt("slotCount", 48),
                codex = parsePoints("codex"),
                codexCredits = parsePoints("codexSpark"),
                claude = parsePoints("claude"),
                claudeFable = parsePoints("claudeFable"),
                gemini = parsePoints("gemini"),
                gemini2 = parsePoints("gemini2"),
                gemini3 = parsePoints("gemini3")
            )
        }

        return UsageSnapshot(
            fetchedAt = fetchedAt,
            publishedAt = publishedAt,
            macAppVersion = appVersion,
            services = services,
            consumptionHistory = history
        )
    }

    private fun optNonBoolDouble(obj: JSONObject, key: String): Double? {
        if (!obj.has(key)) return null
        val v = obj.opt(key)
        if (v is Boolean) return null
        if (v is Number) {
            val d = v.toDouble()
            if (d.isFinite()) return d
        }
        return null
    }

    private fun parseIsoDate(str: String?): Date? {
        if (str.isNullOrBlank()) return null
        return try {
            Date.from(Instant.parse(str))
        } catch (_: Exception) {
            try {
                val zdt = java.time.ZonedDateTime.parse(str, java.time.format.DateTimeFormatter.ISO_DATE_TIME)
                Date.from(zdt.toInstant())
            } catch (_: Exception) {
                null
            }
        }
    }

    private fun saveFileSnapshotCache(bytes: ByteArray) {
        try {
            val file = File(context.filesDir, "last-usage-v1.json")
            val atomicFile = AtomicFile(file)
            var fos: FileOutputStream? = null
            try {
                fos = atomicFile.startWrite()
                fos.write(bytes)
                atomicFile.finishWrite(fos)
            } catch (e: Exception) {
                if (fos != null) atomicFile.failWrite(fos)
            }
        } catch (_: Exception) {}
    }

    private fun loadFileSnapshotCache(): UsageSnapshot? {
        val file = File(context.filesDir, "last-usage-v1.json")
        if (!file.exists()) return null
        return try {
            val atomicFile = AtomicFile(file)
            val bytes = atomicFile.readFully()
            parseSnapshotBytes(bytes)
        } catch (_: Exception) {
            null
        }
    }
}
