package com.armsone.ccmb

import android.Manifest
import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Bundle
import android.view.WindowManager
import android.webkit.CookieManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.armsone.ccmb.catalog.CatalogFixture
import com.armsone.ccmb.store.SnapshotStore
import com.armsone.ccmb.store.WeatherStore
import com.armsone.ccmb.theme.CCMBAppearance
import com.armsone.ccmb.ui.RootScreen

val LocalIsTV = compositionLocalOf { false }

class MainActivity : ComponentActivity() {
    private lateinit var store: SnapshotStore
    private lateinit var weatherStore: WeatherStore
    private var currentTheme by mutableStateOf(CCMBAppearance.LIGHT)
    private var isCatalogMode = false

    private val requestPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { isGranted: Boolean ->
        val prefs = getSharedPreferences("ccmb_prefs", Context.MODE_PRIVATE)
        prefs.edit().putBoolean("weather_permission_requested", true).apply()
        if (isGranted) {
            weatherStore.refresh()
        }
    }

    private fun requestWeatherPermissionOrRefresh() {
        val hasCoarse = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        if (hasCoarse) {
            weatherStore.refresh()
        } else {
            requestPermissionLauncher.launch(Manifest.permission.ACCESS_COARSE_LOCATION)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        // Keep screen on while dashboard is active
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        val isTV = uiModeManager?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION

        // Load appearance preference
        val prefs = getSharedPreferences("ccmb_prefs", Context.MODE_PRIVATE)
        val savedAppearance = prefs.getString("ccmb.appearance", null)
        val systemDark = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        currentTheme = CCMBAppearance.migrated(savedAppearance, systemDark)

        // Optional DEBUG-only ccmb_theme preview override
        if (BuildConfig.DEBUG) {
            val themeExtra = intent?.getStringExtra("ccmb_theme")
            if (!themeExtra.isNullOrBlank()) {
                currentTheme = CCMBAppearance.migrated(themeExtra, systemDark)
            }
        }

        store = SnapshotStore(applicationContext, lifecycleScope)
        weatherStore = WeatherStore(applicationContext, lifecycleScope)
        weatherStore.bindStore(store)

        // Check for catalog mode intent extra with MANDATORY BuildConfig.DEBUG guard
        val catalogExtra = intent?.getStringExtra("ccmb_catalog")
        if (BuildConfig.DEBUG && catalogExtra == "populated") {
            isCatalogMode = true
            store.setCatalogSnapshot(CatalogFixture.createPopulatedSnapshot())
        } else {
            store.loadOnLaunch()

            // Normal coarse location permission request on entry (one-time request)
            val hasCoarse = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.ACCESS_COARSE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED

            if (hasCoarse) {
                weatherStore.refresh()
            } else {
                val weatherRequested = prefs.getBoolean("weather_permission_requested", false)
                if (!weatherRequested) {
                    requestPermissionLauncher.launch(Manifest.permission.ACCESS_COARSE_LOCATION)
                }
            }
        }

        setContent {
            CompositionLocalProvider(LocalIsTV provides isTV) {
                RootScreen(
                    store = store,
                    weatherStore = weatherStore,
                    currentTheme = currentTheme,
                    onSelectTheme = { newTheme ->
                        currentTheme = newTheme
                        prefs.edit().putString("ccmb.appearance", newTheme.rawValue).apply()
                    },
                    onRequestWeather = { requestWeatherPermissionOrRefresh() },
                    isCatalogMode = isCatalogMode
                )
            }
        }
    }

    override fun onStart() {
        super.onStart()
        if (!isCatalogMode) {
            store.resumeAutomaticRefresh()
            weatherStore.resume()
        }
    }

    override fun onStop() {
        super.onStop()
        CookieManager.getInstance().flush()
        if (!isCatalogMode) {
            store.pauseAutomaticRefresh()
            weatherStore.pause()
        }
    }
}
