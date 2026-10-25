package com.armsone.ccmb.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.armsone.ccmb.format.CCMBFormat
import com.armsone.ccmb.model.Service
import com.armsone.ccmb.model.ServiceUsage
import com.armsone.ccmb.model.UsageSnapshot
import com.armsone.ccmb.model.UsageWindow
import com.armsone.ccmb.theme.CCMBTheme
import com.armsone.ccmb.theme.LocalCCMBPalette
import java.util.Date

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ServiceDetailScreen(
    usage: ServiceUsage,
    isNAS: Boolean,
    isBusy: Boolean,
    onBack: () -> Unit
) {
    val palette = LocalCCMBPalette.current
    val service = usage.service
    val isNASToken = isNAS && service == Service.CODEX
    val showsAccount = service != Service.CODEX && service != Service.CLAUDE

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(service.displayName, fontWeight = FontWeight.Bold, color = palette.text) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "뒤로 가기",
                            tint = palette.text
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = palette.bg
                )
            )
        },
        containerColor = palette.bg
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            // Section 1: Quota Windows
            DetailSection(title = "남은 사용량 · 초기화") {
                val detailWindows = usage.windows.filter {
                    !(service == Service.CODEX && it.id == "session" && it.remainingPercent == null)
                }

                detailWindows.forEach { window ->
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 6.dp)
                    ) {
                        LabeledRow(
                            label = "${window.label} 남음",
                            value = CCMBFormat.percent(window.remainingPercent)
                        )
                        Spacer(modifier = Modifier.height(4.dp))

                        val frac = ((window.remainingPercent ?: 0.0) / 100.0).toFloat().coerceIn(0f, 1f)
                        LinearProgressIndicator(
                            progress = { frac },
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(6.dp)
                                .clip(RoundedCornerShape(3.dp)),
                            color = CCMBTheme.gaugeTint(window.remainingPercent, palette),
                            trackColor = palette.surface2
                        )
                        Spacer(modifier = Modifier.height(4.dp))

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Text("초기화", fontSize = 12.sp, color = palette.muted)
                            Text(
                                text = CCMBFormat.resetText(window.resetText) ?: CCMBFormat.resetTime(window.resetsAt),
                                fontSize = 12.sp,
                                color = palette.muted
                            )
                        }

                        // Online note
                        if (window.id.startsWith("online") && window.fetchedAt != null) {
                            val isStale = (Date().time - window.fetchedAt.time) > (UsageSnapshot.staleAfterSeconds * 1000)
                            val prefix = if (isStale) "오래된 값" else "온라인"
                            Text(
                                text = "$prefix · Mac 수집 ${CCMBFormat.resetTime(window.fetchedAt)} · NAS 저장",
                                fontSize = 11.sp,
                                color = palette.muted,
                                modifier = Modifier.padding(top = 2.dp)
                            )
                        }
                    }
                }
            }

            // Section 2: Tokens / Credits
            if (usage.creditBalance != null || usage.monthlyUsedCredits != null || usage.creditUnlimited || isNASToken) {
                DetailSection(title = if (isNASToken) "토큰" else "크레딧") {
                    val label = usage.creditLabel ?: if (isNASToken) "남은 토큰" else "잔액"
                    val value = when {
                        usage.creditUnlimited -> "무제한"
                        usage.creditBalance != null -> CCMBFormat.credits(usage.creditBalance)
                        isNASToken -> "확인 불가"
                        else -> "—"
                    }
                    LabeledRow(label = label, value = value)

                    if (usage.monthlyUsedCredits != null) {
                        LabeledRow(
                            label = "이번 달 사용 크레딧",
                            value = CCMBFormat.credits(usage.monthlyUsedCredits)
                        )
                    }
                }
            }

            // Section 3: Plan & Account
            if ((showsAccount && usage.account != null) || usage.organizationName != null || usage.planTitle != null || usage.model != null) {
                DetailSection(title = if (showsAccount) "계정과 요금제" else "요금제") {
                    if (showsAccount && usage.account != null) {
                        LabeledRow(label = "계정", value = usage.account)
                    }
                    if (usage.organizationName != null) {
                        LabeledRow(label = "조직", value = usage.organizationName)
                    }
                    if (usage.planTitle != null) {
                        LabeledRow(label = "요금제", value = usage.planTitle)
                    }
                    if (usage.model != null) {
                        LabeledRow(label = "모델", value = usage.model)
                    }
                }
            }

            // Section 4: Model Weekly Limits
            if (usage.modelWeeklyLimits.isNotEmpty()) {
                DetailSection(title = "모델별 주간 한도") {
                    usage.modelWeeklyLimits.forEach { limit ->
                        Column(modifier = Modifier.padding(vertical = 4.dp)) {
                            LabeledRow(
                                label = limit.modelName,
                                value = CCMBFormat.percent(limit.remainingPercent)
                            )
                            if (limit.resetsAt != null) {
                                Text(
                                    text = "초기화 ${CCMBFormat.resetTime(limit.resetsAt)}",
                                    fontSize = 11.5.sp,
                                    color = palette.muted
                                )
                            }
                        }
                    }
                }
            }

            // Section 5: Data Information
            DetailSection(title = "데이터 정보") {
                LabeledRow(label = "가져온 시각", value = CCMBFormat.relativeAge(usage.fetchedAt))
                if (usage.fetchedAt != null) {
                    LabeledRow(label = "원본 조회 시각", value = CCMBFormat.resetTime(usage.fetchedAt))
                }
                if (usage.status != null) {
                    val statusDesc = when (usage.status) {
                        "ok" -> "정상"
                        "partial" -> "일부 값만 있음"
                        "stale" -> "저장 당시에도 오래된 값"
                        "unavailable" -> "저장 당시 정보 없음"
                        else -> usage.status
                    }
                    LabeledRow(label = "상태", value = statusDesc)
                }
                if (usage.errorReason != null) {
                    LabeledRow(label = "사유", value = usage.errorReason)
                }
                if (usage.isLastKnown) {
                    Text(
                        text = "최신 조회가 실패해 이 계정의 마지막 정상값을 원본 조회 시각과 함께 표시합니다.",
                        fontSize = 12.sp,
                        color = palette.muted
                    )
                }
                if (isBusy) {
                    Text(
                        text = "NAS가 지금 수집 중입니다. 끝나면 다음 새로 고침에 반영됩니다.",
                        fontSize = 12.sp,
                        color = palette.muted
                    )
                }
                if (showsAccount && usage.accountDisplay != null) {
                    LabeledRow(label = "계정", value = usage.accountDisplay!!)
                }

                val explanation = if (isNAS) {
                    val base = "이 값은 NAS에서 직접 조회한 실시간 사용량입니다."
                    if (isNASToken) "$base 토큰 잔액은 플레이그라운드가 보고하는 잔액이며, 입력/출력 토큰 소비량이 아닙니다." else base
                } else {
                    "이 값은 Mac의 CCMB가 기록한 스냅샷(iCloud 또는 파일)에서 읽은 것입니다. Android 기기에서 직접 조회한 값이 아닙니다."
                }
                Text(
                    text = explanation,
                    fontSize = 12.sp,
                    color = palette.muted
                )
            }

            // Section 6: Reset Vouchers
            if (usage.codexResetCreditsAvailable != null || usage.codexResetCreditExpirations.isNotEmpty()) {
                DetailSection(title = "초기화") {
                    if (usage.codexResetCreditsAvailable != null) {
                        LabeledRow(label = "개수", value = "${usage.codexResetCreditsAvailable}개")
                    }
                    usage.codexResetCreditExpirations.forEach { exp ->
                        Text(
                            text = CCMBFormat.resetTime(exp),
                            fontSize = 12.sp,
                            fontFamily = FontFamily.Monospace,
                            color = palette.muted
                        )
                    }
                }
            }

            if (usage.claudeLimitResetsCount != null) {
                DetailSection(title = "초기화") {
                    LabeledRow(label = "개수", value = "${usage.claudeLimitResetsCount}")
                    if (usage.claudeLimitResetsExpiresAt != null) {
                        Text(
                            text = CCMBFormat.resetTime(usage.claudeLimitResetsExpiresAt),
                            fontSize = 12.sp,
                            fontFamily = FontFamily.Monospace,
                            color = palette.muted
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun DetailSection(
    title: String,
    content: @Composable () -> Unit
) {
    val palette = LocalCCMBPalette.current

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(palette.card)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Text(
            text = title,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            color = palette.accent
        )
        content()
    }
}

@Composable
fun LabeledRow(label: String, value: String) {
    val palette = LocalCCMBPalette.current

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(text = label, fontSize = 13.5.sp, color = palette.text)
        Text(text = value, fontSize = 13.5.sp, fontWeight = FontWeight.Medium, color = palette.text)
    }
}
