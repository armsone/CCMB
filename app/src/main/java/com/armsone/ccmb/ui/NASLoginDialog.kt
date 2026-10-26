package com.armsone.ccmb.ui

import android.annotation.SuppressLint
import android.net.Uri
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
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import java.util.concurrent.atomic.AtomicBoolean

private fun isSameOriginUri(uri: Uri?): Boolean {
    if (uri == null) return false
    return uri.scheme.equals("https", ignoreCase = true) &&
            uri.host.equals(NASConfig.allowedHost, ignoreCase = true) &&
            (uri.port == NASConfig.allowedPort || (uri.port == -1 && NASConfig.allowedPort == 443))
}

private fun isSameOriginUrl(urlStr: String?): Boolean {
    if (urlStr == null) return false
    return try {
        val uri = Uri.parse(urlStr)
        isSameOriginUri(uri)
    } catch (_: Exception) {
        false
    }
}

/**
 * NAS 웹 로그인 모달:
 * - decorFitsSystemWindows = false 와 Scaffold(contentWindowInsets = WindowInsets.safeDrawing)을
 *   사용하여 시스템바/IME 인셋을 일관되게 단 1회 적용한다.
 * - 별도의 네이티브 하단 버튼/문구를 배제하고 웹 폼의 원래 제출 버튼을 단독으로 사용한다.
 * - 키보드가 올라오면 WebView 가 자동으로 줄어들고 스크롤되어 웹 폼 제출 버튼에 접근할 수 있다.
 * - 모달 활성 상태 동안 단일 코루틴이 800ms 주기로 NASClient.checkSession()을 비동기 관찰하여,
 *   인증 완료 시 쿠키 플러시 및 store.connectNAS()를 1회 실행 후 즉시 닫힌다.
 * - 동일 출처 검증과 TLS 오류 거부를 엄격히 유지하며 JS 브리지나 자격 증명 추출은 사용하지 않는다.
 */
@OptIn(ExperimentalMaterial3Api::class)
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun NASLoginDialog(
    store: SnapshotStore,
    onDismiss: () -> Unit
) {
    val palette = LocalCCMBPalette.current
    var blockedNavigation by remember { mutableStateOf(false) }
    var webViewRef by remember { mutableStateOf<WebView?>(null) }
    var hasConnected by remember { mutableStateOf(false) }
    val isDisposed = remember { AtomicBoolean(false) }

    LaunchedEffect(Unit) {
        while (isActive && !isDisposed.get() && !hasConnected) {
            val authenticated = try {
                NASClient.checkSession()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                false
            }

            if (authenticated) {
                if (isActive && !isDisposed.get() && !hasConnected) {
                    hasConnected = true
                    CookieManager.getInstance().flush()
                    store.connectNAS()
                    onDismiss()
                }
                break
            }

            delay(800L)
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            isDisposed.set(true)
            CookieManager.getInstance().flush()
            webViewRef?.let { wv ->
                (wv.parent as? ViewGroup)?.removeView(wv)
                wv.stopLoading()
                wv.loadUrl("about:blank")
                wv.clearHistory()
                wv.removeAllViews()
                wv.destroy()
                webViewRef = null
            }
        }
    }

    Dialog(
        onDismissRequest = {
            CookieManager.getInstance().flush()
            onDismiss()
        },
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
                        IconButton(onClick = {
                            CookieManager.getInstance().flush()
                            onDismiss()
                        }) {
                            Icon(Icons.Default.Close, contentDescription = "취소", tint = palette.text)
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = palette.surface)
                )
            },
            contentWindowInsets = WindowInsets.safeDrawing,
            containerColor = palette.bg
        ) { padding ->
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
                                    override fun shouldOverrideUrlLoading(
                                        view: WebView?,
                                        request: WebResourceRequest?
                                    ): Boolean {
                                        val uri = request?.url ?: return false
                                        return if (isSameOriginUri(uri)) {
                                            false
                                        } else {
                                            blockedNavigation = true
                                            true
                                        }
                                    }

                                    override fun onPageFinished(view: WebView?, url: String?) {
                                        super.onPageFinished(view, url)
                                        if (url != null && isSameOriginUrl(url)) {
                                            view?.evaluateJavascript(
                                                """
                                                (function() {
                                                    if (document.getElementById('ccmb-auth-hide-style')) return;
                                                    var style = document.createElement('style');
                                                    style.id = 'ccmb-auth-hide-style';
                                                    style.textContent = '#app:not(:has(#loginForm)) { display: none !important; }';
                                                    (document.head || document.documentElement).appendChild(style);
                                                })();
                                                """.trimIndent(),
                                                null
                                            )
                                        }
                                    }

                                    override fun onReceivedSslError(
                                        view: WebView?,
                                        handler: SslErrorHandler?,
                                        error: SslError?
                                    ) {
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
