package com.armsone.ccmb.ui

import android.annotation.SuppressLint
import android.net.http.SslError
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.SslErrorHandler
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.armsone.ccmb.store.NASClient
import com.armsone.ccmb.store.NASConfig
import com.armsone.ccmb.store.SnapshotStore
import com.armsone.ccmb.theme.LocalCCMBPalette
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * 인셋 처리 전략(한 가지로 고정):
 * - Dialog 는 decorFitsSystemWindows = false 로 열어 창이 시스템바/IME 아래까지 깔리고, 인셋은
 *   Compose 가 직접 받는다. targetSdk 35+ 의 edge-to-edge 강제 하에서는 기본값(true)이어도 창이
 *   어차피 edge-to-edge 가 되고 ADJUST_RESIZE 가 무시되어, 하단 로그인 버튼이 제스처 바/키보드
 *   밑에 깔리는 실사용 버그가 있었다. 명시적으로 false 로 두면 API 레벨과 무관하게 같은 경로를 탄다.
 * - 상단바는 TopAppBar 기본 windowInsets(상태바)을, 하단바는 safeDrawing 의 하단+좌우(내비게이션
 *   바 ∪ IME ∪ 컷아웃, 합산이 아니라 최대값)를 각자 한 번씩만 소비한다.
 * - Scaffold 의 content padding 하단은 bottomBar 의 실제 높이(IME 패딩 포함)이므로, 키보드가
 *   올라오면 WebView 영역이 그만큼 줄고(내부 스크롤), 버튼은 항상 키보드 바로 위에 고정된다.
 * 인증 쿠키/TLS/오리진 검사/세션 확인/폼 제출 동작은 변경하지 않는다.
 */
@OptIn(ExperimentalMaterial3Api::class)
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun NASLoginDialog(
    store: SnapshotStore,
    onDismiss: () -> Unit
) {
    val palette = LocalCCMBPalette.current
    val scope = rememberCoroutineScope()
    var isVerifying by remember { mutableStateOf(false) }
    var blockedNavigation by remember { mutableStateOf(false) }
    var webViewRef by remember { mutableStateOf<WebView?>(null) }
    var pollJob by remember { mutableStateOf<Job?>(null) }

    fun verifyNow() {
        pollJob?.cancel()
        pollJob = scope.launch {
            isVerifying = true
            try {
                for (attempt in 0 until 6) {
                    if (NASClient.checkSession()) {
                        store.connectNAS()
                        onDismiss()
                        return@launch
                    }
                    if (attempt < 5) delay(400)
                }
            } finally {
                isVerifying = false
            }
        }
    }

    LaunchedEffect(Unit) {
        verifyNow()
    }

    DisposableEffect(Unit) {
        onDispose {
            pollJob?.cancel()
        }
    }

    // 가로 모드/짧은 화면(예: 폰 가로 ≈ 360dp 이하)에서는 안내 문구를 접어 WebView 영역을 확보한다.
    val isShortHeight = LocalConfiguration.current.screenHeightDp < 480

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false
        )
    ) {
        Scaffold(
            modifier = Modifier.fillMaxSize(),
            topBar = {
                TopAppBar(
                    title = { Text("NAS 로그인", fontWeight = FontWeight.Bold, color = palette.text) },
                    navigationIcon = {
                        IconButton(onClick = onDismiss) {
                            Icon(Icons.Default.Close, contentDescription = "취소", tint = palette.text)
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = palette.surface)
                )
            },
            bottomBar = {
                // 하단 고정 영역: 배경은 시스템바 아래까지 깔고, 내용만 내비게이션 바/IME/컷아웃만큼 띄운다.
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(palette.surface)
                        .windowInsetsPadding(
                            WindowInsets.safeDrawing.only(WindowInsetsSides.Bottom + WindowInsetsSides.Horizontal)
                        )
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    if (!isShortHeight) {
                        Text(
                            text = "비밀번호를 입력하고 아래 로그인 버튼을 눌러 주세요.",
                            fontSize = 12.sp,
                            color = palette.muted,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.padding(bottom = 8.dp)
                        )
                    }

                    Button(
                        onClick = {
                            webViewRef?.evaluateJavascript(
                                """
                                (() => {
                                    const form = document.getElementById('loginForm');
                                    if (!form || form.hidden) return false;
                                    form.requestSubmit();
                                    return true;
                                })()
                                """.trimIndent()
                            ) { result ->
                                verifyNow()
                            }
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 48.dp),
                        enabled = !isVerifying,
                        colors = ButtonDefaults.buttonColors(containerColor = palette.accent),
                        shape = RoundedCornerShape(8.dp)
                    ) {
                        if (isVerifying) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(20.dp),
                                color = palette.onAccent,
                                strokeWidth = 2.dp
                            )
                        } else {
                            Text("로그인", color = palette.onAccent, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            },
            containerColor = palette.bg
        ) { padding ->
            // padding: 상단 = TopAppBar 높이, 하단 = bottomBar 실제 높이(IME 포함), 좌우 = 시스템바 인셋.
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
            ) {
                if (blockedNavigation) {
                    Text(
                        text = "NAS 로그인 페이지 밖으로는 이동할 수 없습니다. 로그인 페이지로 돌아가 다시 시도해 주세요.",
                        color = palette.danger,
                        fontSize = 12.sp,
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(palette.dangerSoft)
                            .padding(8.dp)
                    )
                }

                // WebView: 남는 높이를 모두 쓰고, 키보드가 올라오면 그만큼 줄어들며 내부에서 스크롤된다.
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                ) {
                    AndroidView(
                        factory = { ctx ->
                            WebView(ctx).apply {
                                layoutParams = ViewGroup.LayoutParams(
                                    ViewGroup.LayoutParams.MATCH_PARENT,
                                    ViewGroup.LayoutParams.MATCH_PARENT
                                )
                                settings.javaScriptEnabled = true
                                settings.domStorageEnabled = true
                                settings.allowContentAccess = false
                                settings.allowFileAccess = false

                                val cookieManager = CookieManager.getInstance()
                                cookieManager.setAcceptCookie(true)
                                cookieManager.setAcceptThirdPartyCookies(this, false)

                                webViewClient = object : WebViewClient() {
                                    override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                                        val uri = request?.url ?: return false
                                        val isAllowed = uri.scheme.equals("https", ignoreCase = true) &&
                                                uri.host.equals(NASConfig.allowedHost, ignoreCase = true) &&
                                                (uri.port == NASConfig.allowedPort || (uri.port == -1 && NASConfig.allowedPort == 443))
                                        return if (isAllowed) {
                                            false
                                        } else {
                                            blockedNavigation = true
                                            true
                                        }
                                    }

                                    override fun onPageFinished(view: WebView?, url: String?) {
                                        super.onPageFinished(view, url)
                                        if (NASClient.hasSessionCookie()) {
                                            verifyNow()
                                        }
                                    }

                                    override fun onReceivedSslError(view: WebView?, handler: SslErrorHandler?, error: SslError?) {
                                        // Never bypass SSL errors
                                        handler?.cancel()
                                    }
                                }

                                webViewRef = this
                                loadUrl(NASConfig.baseURLString)
                            }
                        },
                        modifier = Modifier.fillMaxSize()
                    )
                }
            }
        }
    }
}
