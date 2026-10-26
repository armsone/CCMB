package com.armsone.ccmb.model

data class NASTaskStatus(
    val running: Int,
    val preparing: Int,
    val waiting: Int,
    val capturedAtMs: Long
)

/** counts 는 마지막 성공값(없으면 null). failed 는 최근 조회 실패 여부. */
data class NASTaskStatusState(
    val counts: NASTaskStatus? = null,
    val failed: Boolean = false
) {
    companion object {
        const val STALE_AFTER_MS = 240_000L
    }

    fun isStale(nowMs: Long): Boolean =
        counts != null && nowMs - counts.capturedAtMs > STALE_AFTER_MS

    fun accessibilityLabel(nowMs: Long): String {
        val c = counts ?: return if (failed) "플레이그라운드 상태 연결 확인 필요" else "플레이그라운드 상태 확인 중"
        val base = "플레이그라운드 실행 ${c.running}, 준비 ${c.preparing}, 대기 ${c.waiting}"
        return if (failed || isStale(nowMs)) "$base. 최신 상태를 확인하지 못했습니다" else base
    }
}
