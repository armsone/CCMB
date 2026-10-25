package com.armsone.ccmb.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.armsone.ccmb.R
import com.armsone.ccmb.store.SnapshotStore
import com.armsone.ccmb.theme.LocalCCMBPalette

@Composable
fun WelcomeScreen(
    store: SnapshotStore,
    modifier: Modifier = Modifier
) {
    val palette = LocalCCMBPalette.current
    val nasConnecting by store.nasConnecting.collectAsState()
    val nasConnectError by store.nasConnectError.collectAsState()
    val refreshProblem by store.refreshProblem.collectAsState()

    val filePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        if (uri != null) {
            store.importPickedFile(uri, uri.lastPathSegment)
        }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(palette.bg)
            .statusBarsPadding()
            .navigationBarsPadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 24.dp, vertical = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(20.dp)
    ) {
        // Brand Icon (96x96dp)
        Image(
            painter = painterResource(id = R.drawable.ccmb_brand_icon),
            contentDescription = null,
            modifier = Modifier
                .size(96.dp)
                .clip(RoundedCornerShape(22.dp)),
            contentScale = ContentScale.Fit
        )

        // Headings
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Text(
                text = "Codex · Claude · Gemini",
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
                color = palette.text
            )
            Text(
                text = "집 NAS에 모인 사용량을 어디서든 확인합니다.",
                fontSize = 14.sp,
                color = palette.muted,
                textAlign = TextAlign.Center
            )
        }

        // Steps card
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(palette.card)
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            StepRow(number = 1, text = "아래 버튼으로 NAS에 로그인하세요.")
            StepRow(number = 2, text = "이후에는 앱을 열거나 당겨서 새로 고침할 때마다 최신 값을 읽습니다.")
        }

        // Error banner if any
        val errorToShow = refreshProblem ?: nasConnectError
        if (errorToShow != null) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(palette.card)
                    .padding(12.dp),
                verticalAlignment = Alignment.Top
            ) {
                Icon(
                    imageVector = Icons.Default.Warning,
                    contentDescription = null,
                    tint = palette.danger,
                    modifier = Modifier.size(20.dp)
                )
                Spacer(modifier = Modifier.width(10.dp))
                Text(
                    text = errorToShow,
                    fontSize = 12.5.sp,
                    color = palette.danger
                )
            }
        }

        Text(
            text = "사용량은 집 NAS에서 직접 읽어 옵니다.",
            fontSize = 12.sp,
            color = palette.muted,
            textAlign = TextAlign.Center
        )

        // Main CTA button
        Button(
            onClick = { store.requestNASLogin() },
            modifier = Modifier
                .fillMaxWidth()
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
                    text = "NAS에서 불러오기",
                    color = palette.bg,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold
                )
            }
        }

        // SAF Local JSON import button
        OutlinedButton(
            onClick = { filePicker.launch(arrayOf("application/json", "*/*")) },
            modifier = Modifier
                .fillMaxWidth()
                .height(44.dp),
            shape = RoundedCornerShape(12.dp)
        ) {
            Text(
                text = "로컬 파일(JSON)에서 가져오기",
                color = palette.text,
                fontSize = 13.5.sp
            )
        }
    }
}

@Composable
private fun StepRow(number: Int, text: String) {
    val palette = LocalCCMBPalette.current

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .semantics { contentDescription = "${number}단계. $text" },
        verticalAlignment = Alignment.Top
    ) {
        Box(
            modifier = Modifier
                .size(24.dp)
                .clip(CircleShape)
                .background(palette.text),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = "$number",
                color = palette.bg,
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold
            )
        }
        Spacer(modifier = Modifier.width(12.dp))
        Text(
            text = text,
            color = palette.text,
            fontSize = 13.5.sp,
            lineHeight = 19.sp
        )
    }
}
