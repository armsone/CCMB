package com.armsone.ccmb.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.armsone.ccmb.model.ServiceUsage
import com.armsone.ccmb.store.LoadState
import com.armsone.ccmb.store.SnapshotStore
import com.armsone.ccmb.store.WeatherStore
import com.armsone.ccmb.theme.CCMBAppearance
import com.armsone.ccmb.theme.LocalCCMBPalette

@Composable
fun RootScreen(
    store: SnapshotStore,
    weatherStore: WeatherStore,
    currentTheme: CCMBAppearance,
    onSelectTheme: (CCMBAppearance) -> Unit,
    onRequestWeather: () -> Unit = {},
    isCatalogMode: Boolean = false,
    modifier: Modifier = Modifier
) {
    val palette = currentTheme.palette
    val loadState by store.state.collectAsState()
    val isNASLoginPresented by store.isNASLoginPresented.collectAsState()
    var selectedService by remember { mutableStateOf<ServiceUsage?>(null) }

    val filePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        if (uri != null) {
            store.importPickedFile(uri, uri.lastPathSegment)
        }
    }

    CompositionLocalProvider(LocalCCMBPalette provides palette) {
        Box(
            modifier = modifier
                .fillMaxSize()
                .background(palette.bg)
        ) {
            when (val state = loadState) {
                is LoadState.Empty -> {
                    WelcomeScreen(store = store)
                }
                is LoadState.Loading -> {
                    Column(
                        modifier = Modifier.fillMaxSize(),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center
                    ) {
                        CircularProgressIndicator(
                            color = palette.accent,
                            modifier = Modifier.size(36.dp),
                            strokeWidth = 3.dp
                        )
                        Spacer(modifier = Modifier.height(12.dp))
                        Text(
                            text = "사용량을 불러오는 중…",
                            color = palette.muted,
                            fontSize = 14.sp
                        )
                    }
                }
                is LoadState.Loaded -> {
                    val currentSelected = selectedService
                    if (currentSelected != null) {
                        ServiceDetailScreen(
                            usage = currentSelected,
                            isNAS = store.displayedSource.value == com.armsone.ccmb.model.PreferredSource.NAS,
                            isBusy = store.nasRefreshBusy.collectAsState().value,
                            onBack = { selectedService = null }
                        )
                    } else {
                        DashboardScreen(
                            snapshot = state.snapshot,
                            store = store,
                            weatherStore = weatherStore,
                            currentTheme = currentTheme,
                            onSelectTheme = onSelectTheme,
                            onSelectService = { selectedService = it },
                            onOpenFilePicker = { filePicker.launch(arrayOf("application/json", "*/*")) },
                            onRequestWeather = onRequestWeather,
                            isCatalogMode = isCatalogMode
                        )
                    }
                }
                is LoadState.Failed -> {
                    FailureScreen(message = state.message, store = store)
                }
            }

            // Modal sheet for NAS login
            if (isNASLoginPresented) {
                NASLoginDialog(
                    store = store,
                    onDismiss = { store.dismissNASLogin() }
                )
            }
        }
    }
}
