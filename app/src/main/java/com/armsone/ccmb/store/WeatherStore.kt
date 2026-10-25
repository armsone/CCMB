package com.armsone.ccmb.store

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Looper
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.min

data class HourlyForecast(
    val timeIso: String,
    val timeLabel: String,
    val hour: Int,
    val temperature: Double,
    val weatherCode: Int,
    val symbolName: String,
    val precipitationProbability: Int?
)

data class DailyForecast(
    val dateIso: String,
    val dayLabel: String,
    val weatherCode: Int,
    val symbolName: String,
    val maxTemp: Double,
    val minTemp: Double,
    val precipitationProbability: Int?
)

data class WeatherReading(
    val temperature: Double,
    val weatherCode: Int,
    val symbolName: String,
    val hourly: List<HourlyForecast> = emptyList(),
    val daily: List<DailyForecast> = emptyList(),
    val updatedAt: Date = Date(),
    val isStale: Boolean = false,
    val errorMessage: String? = null
)

class WeatherStore(private val context: Context, private val scope: CoroutineScope) {
    private val _reading = MutableStateFlow<WeatherReading?>(null)
    val reading: StateFlow<WeatherReading?> = _reading.asStateFlow()

    private var isLoading = false
    private var isForeground = true
    private var observingJob: Job? = null
    private var fetchJob: Job? = null
    private var lastTriggerTime = 0L

    fun bindStore(store: SnapshotStore) {
        observingJob?.cancel()
        observingJob = scope.launch {
            store.nextAutomaticRefreshAt.collect { nextDate ->
                if (nextDate != null && isForeground) {
                    val now = System.currentTimeMillis()
                    if (now - lastTriggerTime > 5000L) {
                        lastTriggerTime = now
                        refresh()
                    }
                }
            }
        }
    }

    fun pause() {
        isForeground = false
        fetchJob?.cancel()
        fetchJob = null
        isLoading = false
    }

    fun resume() {
        val wasPaused = !isForeground
        isForeground = true
        if (wasPaused) {
            refresh()
        }
    }

    fun refresh() {
        if (!isForeground) return

        val hasCoarse = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        if (!hasCoarse) {
            _reading.value = null
            return
        }

        requestLocation()
    }

    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    private fun requestLocation() {
        val locationManager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return

        var lastKnown: Location? = null
        val providers = listOf(LocationManager.NETWORK_PROVIDER, LocationManager.PASSIVE_PROVIDER)
        for (p in providers) {
            try {
                if (locationManager.isProviderEnabled(p)) {
                    val loc = locationManager.getLastKnownLocation(p)
                    if (loc != null && (lastKnown == null || loc.time > lastKnown.time)) {
                        lastKnown = loc
                    }
                }
            } catch (_: Exception) {}
        }

        // Fresh if under 30 minutes old
        val isFresh = lastKnown != null && (System.currentTimeMillis() - lastKnown.time) < 30 * 60 * 1000L
        if (isFresh && lastKnown != null) {
            fetchWeather(lastKnown.latitude, lastKnown.longitude)
            return
        }

        val isNetworkEnabled = try {
            locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        } catch (_: Exception) {
            false
        }

        if (!isNetworkEnabled) {
            // Disabled provider: fallback to lastKnown if available, else stay null quietly
            if (lastKnown != null) {
                fetchWeather(lastKnown.latitude, lastKnown.longitude)
            }
            return
        }

        val fallbackLocation = lastKnown
        scope.launch(Dispatchers.Main) {
            var isCleanedUp = false
            var listener: LocationListener? = null

            fun cleanup() {
                if (!isCleanedUp) {
                    isCleanedUp = true
                    listener?.let {
                        try {
                            locationManager.removeUpdates(it)
                        } catch (_: Exception) {}
                    }
                }
            }

            listener = object : LocationListener {
                override fun onLocationChanged(location: Location) {
                    cleanup()
                    if (isForeground) {
                        fetchWeather(location.latitude, location.longitude)
                    }
                }

                override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
                override fun onProviderEnabled(provider: String) {}
                override fun onProviderDisabled(provider: String) {
                    cleanup()
                    if (fallbackLocation != null && _reading.value == null && isForeground) {
                        fetchWeather(fallbackLocation.latitude, fallbackLocation.longitude)
                    }
                }
            }

            try {
                locationManager.requestSingleUpdate(
                    LocationManager.NETWORK_PROVIDER,
                    listener,
                    Looper.getMainLooper()
                )
            } catch (_: Exception) {
                cleanup()
                if (fallbackLocation != null && _reading.value == null && isForeground) {
                    fetchWeather(fallbackLocation.latitude, fallbackLocation.longitude)
                }
                return@launch
            }

            // Bounded timeout: wait up to 10 seconds for location fix
            delay(10_000L)
            if (!isCleanedUp) {
                cleanup()
                if (fallbackLocation != null && _reading.value == null && isForeground) {
                    fetchWeather(fallbackLocation.latitude, fallbackLocation.longitude)
                }
            }
        }
    }

    private fun fetchWeather(latitude: Double, longitude: Double) {
        if (isLoading || !isForeground) return
        isLoading = true

        fetchJob?.cancel()
        fetchJob = scope.launch {
            try {
                val reading = withContext(Dispatchers.IO) {
                    val urlStr = String.format(
                        Locale.US,
                        "https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&current=temperature_2m,weather_code,is_day&hourly=temperature_2m,weather_code,precipitation_probability&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=auto&forecast_days=7&temperature_unit=celsius",
                        latitude,
                        longitude
                    )
                    val conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                        requestMethod = "GET"
                        connectTimeout = 8000
                        readTimeout = 8000
                    }
                    try {
                        if (conn.responseCode == 200) {
                            val text = conn.inputStream.bufferedReader().use { it.readText() }
                            val json = JSONObject(text)
                            parseOpenMeteoJson(json)
                        } else null
                    } finally {
                        conn.disconnect()
                    }
                }
                if (reading != null) {
                    _reading.value = reading
                } else if (_reading.value != null) {
                    _reading.value = _reading.value?.copy(isStale = true, errorMessage = "날씨 정보 파싱 실패")
                }
            } catch (_: Exception) {
                // Network failure retains old values honestly; display updated time or stale state.
                if (_reading.value != null) {
                    _reading.value = _reading.value?.copy(isStale = true, errorMessage = "날씨 새로고침 실패")
                }
            } finally {
                isLoading = false
            }
        }
    }

    private fun parseOpenMeteoJson(json: JSONObject): WeatherReading? {
        val current = json.optJSONObject("current") ?: return null
        if (!current.has("temperature_2m") || current.isNull("temperature_2m") ||
            !current.has("weather_code") || current.isNull("weather_code")
        ) {
            return null
        }

        val temp = current.optDouble("temperature_2m")
        val code = current.optInt("weather_code", -1)
        val isDay = current.optInt("is_day", 1) == 1
        if (temp.isNaN() || temp.isInfinite() || code < 0) return null

        val currentSymbol = wmoToSymbol(code, isDay)

        // Hourly forecast
        val hourlyList = mutableListOf<HourlyForecast>()
        val hourlyObj = json.optJSONObject("hourly")
        if (hourlyObj != null) {
            val hTimes = hourlyObj.optJSONArray("time")
            val hTemps = hourlyObj.optJSONArray("temperature_2m")
            val hCodes = hourlyObj.optJSONArray("weather_code")
            val hPrecips = hourlyObj.optJSONArray("precipitation_probability")
            if (hTimes != null && hTemps != null && hCodes != null) {
                val count = hTimes.length()
                val currentPrefix = SimpleDateFormat("yyyy-MM-dd'T'HH", Locale.US).format(Date())
                var startIdx = 0
                for (i in 0 until count) {
                    val t = hTimes.optString(i)
                    if (t.startsWith(currentPrefix) || t >= currentPrefix) {
                        startIdx = i
                        break
                    }
                }
                val endIdx = min(count, startIdx + 24)
                for (i in startIdx until endIdx) {
                    val tStr = hTimes.optString(i)
                    val hTemp = hTemps.optDouble(i)
                    val hCode = hCodes.optInt(i, 0)
                    val hPrecip = if (hPrecips != null && !hPrecips.isNull(i)) hPrecips.optInt(i) else null
                    val hourPart = tStr.substringAfter("T", "").substringBefore(":", "")
                    val hourInt = hourPart.toIntOrNull() ?: (i % 24)
                    val label = if (i == startIdx) "지금" else "${hourInt}시"
                    val isDayHour = hourInt in 6..18
                    if (!hTemp.isNaN() && !hTemp.isInfinite()) {
                        hourlyList.add(
                            HourlyForecast(
                                timeIso = tStr,
                                timeLabel = label,
                                hour = hourInt,
                                temperature = hTemp,
                                weatherCode = hCode,
                                symbolName = wmoToSymbol(hCode, isDayHour),
                                precipitationProbability = hPrecip
                            )
                        )
                    }
                }
            }
        }

        // 7-day daily forecast
        val dailyList = mutableListOf<DailyForecast>()
        val dailyObj = json.optJSONObject("daily")
        if (dailyObj != null) {
            val dTimes = dailyObj.optJSONArray("time")
            val dCodes = dailyObj.optJSONArray("weather_code")
            val dMaxs = dailyObj.optJSONArray("temperature_2m_max")
            val dMins = dailyObj.optJSONArray("temperature_2m_min")
            val dPrecips = dailyObj.optJSONArray("precipitation_probability_max")
            if (dTimes != null && dCodes != null && dMaxs != null && dMins != null) {
                val count = min(7, dTimes.length())
                val isoFormat = SimpleDateFormat("yyyy-MM-dd", Locale.US)
                val dayOfWeekFormat = SimpleDateFormat("E", Locale.KOREA)
                for (i in 0 until count) {
                    val dStr = dTimes.optString(i)
                    val dCode = dCodes.optInt(i, 0)
                    val maxT = dMaxs.optDouble(i)
                    val minT = dMins.optDouble(i)
                    val dPrecip = if (dPrecips != null && !dPrecips.isNull(i)) dPrecips.optInt(i) else null
                    val dayLabel = if (i == 0) {
                        "오늘"
                    } else {
                        try {
                            val parsed = isoFormat.parse(dStr)
                            if (parsed != null) dayOfWeekFormat.format(parsed) else "${i}일후"
                        } catch (_: Exception) {
                            "${i}일후"
                        }
                    }
                    if (!maxT.isNaN() && !maxT.isInfinite() && !minT.isNaN() && !minT.isInfinite()) {
                        dailyList.add(
                            DailyForecast(
                                dateIso = dStr,
                                dayLabel = dayLabel,
                                weatherCode = dCode,
                                symbolName = wmoToSymbol(dCode, isDay = true),
                                maxTemp = maxT,
                                minTemp = minT,
                                precipitationProbability = dPrecip
                            )
                        )
                    }
                }
            }
        }

        return WeatherReading(
            temperature = temp,
            weatherCode = code,
            symbolName = currentSymbol,
            hourly = hourlyList,
            daily = dailyList,
            updatedAt = Date(),
            isStale = false,
            errorMessage = null
        )
    }

    fun wmoToSymbol(code: Int, isDay: Boolean = true): String = when (code) {
        0 -> if (isDay) "sun" else "sun"
        1, 2 -> "cloud_sun"
        3 -> "cloud"
        45, 48 -> "fog"
        in 51..57 -> "drizzle"
        in 61..67, in 80..82 -> "rain"
        in 71..77, 85, 86 -> "snow"
        in 95..99 -> "thunder"
        else -> "cloud"
    }
}
