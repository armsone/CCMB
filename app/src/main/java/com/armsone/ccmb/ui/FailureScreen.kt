package com.armsone.ccmb.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.armsone.ccmb.store.SnapshotStore
import com.armsone.ccmb.theme.LocalCCMBPalette

@Composable
fun FailureScreen(
    message: String,
    store: SnapshotStore,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current
    val nasConnecting by store.nasConnecting.collectAsState()
    val nasConnectError by store.nasConnectError.collectAsState()

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(palette.bg)
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Icon(
            imageVector = Icons.Default.Warning,
            contentDescription = null,
            tint = palette.danger,
            modifier = Modifier.size(54.dp)
        )

        Spacer(modifier = Modifier.height(20.dp))

        Text(
            text = message,
            fontSize = 15.sp,
            color = palette.text,
            textAlign = TextAlign.Center,
            lineHeight = 22.sp,
            modifier = Modifier.padding(horizontal = 16.dp)
        )

        Spacer(modifier = Modifier.height(24.dp))

        Button(
            onClick = { store.requestNASLogin() },
            modifier = Modifier
                .fillMaxWidth(0.85f)
                .height(48.dp),
            enabled = !nasConnecting,
            colors = ButtonDefaults.buttonColors(containerColor = palette.text),
            shape = RoundedCornerShape(12.dp)
        ) {
            if (nasConnecting) {
                CircularProgressIndicator(
                    modifier = Modifier.size(20.dp),
                    color = palette.bg,
                    strokeWidth = 2.dp
                )
            } else {
                Text(
                    text = "NAS에서 다시 불러오기",
                    color = palette.bg,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold
                )
            }
        }

        if (nasConnectError != null) {
            Spacer(modifier = Modifier.height(12.dp))
            Text(
                text = nasConnectError!!,
                fontSize = 12.sp,
                color = palette.danger,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 24.dp)
            )
        }
    }
}
