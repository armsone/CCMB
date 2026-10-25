package com.armsone.ccmb.theme

import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.graphics.Color
import com.armsone.ccmb.model.Service

data class CCMBPalette(
    val bg: Color,
    val card: Color,
    val surface: Color,
    val surface2: Color,
    val text: Color,
    val text2: Color,
    val muted: Color,
    val border: Color,
    val border2: Color,
    val accent: Color,
    val accentStrong: Color,
    val accentSoft: Color,
    val onAccent: Color,
    val warn: Color,
    val warnSoft: Color,
    val warnInk: Color,
    val danger: Color,
    val dangerSoft: Color
) {
    val isDark: Boolean
        get() = this == jarvis || this == ultron

    companion object {
        private fun hex(value: Long): Color = Color(
            red = ((value shr 16) and 0xFF).toInt(),
            green = ((value shr 8) and 0xFF).toInt(),
            blue = (value and 0xFF).toInt(),
            alpha = 0xFF
        )

        val light = CCMBPalette(
            bg = hex(0xf5f4f0), card = hex(0xfbfaf7), surface = hex(0xffffff), surface2 = hex(0xecebe4),
            text = hex(0x1f211c), text2 = hex(0x4a4c44), muted = hex(0x666860),
            border = hex(0xe2dfd5), border2 = hex(0xd0cdc0),
            accent = hex(0x5c6b3c), accentStrong = hex(0x46532c), accentSoft = hex(0xe8ebdb), onAccent = hex(0xffffff),
            warn = hex(0x9c5415), warnSoft = hex(0xf7e9d8), warnInk = hex(0x6d3c10),
            danger = hex(0x9c3b2a), dangerSoft = hex(0xf6e3de)
        )

        val friday = CCMBPalette(
            bg = hex(0xf7efe3), card = hex(0xfffaf1), surface = hex(0xfffdf8), surface2 = hex(0xf0e2cc),
            text = hex(0x2a1f16), text2 = hex(0x55422f), muted = hex(0x725b45),
            border = hex(0xe8d8c0), border2 = hex(0xd3bb98),
            accent = hex(0x9a4a12), accentStrong = hex(0x743508), accentSoft = hex(0xf6dfc0), onAccent = hex(0xffffff),
            warn = hex(0x8a5a00), warnSoft = hex(0xf8e6b8), warnInk = hex(0x6d3c10),
            danger = hex(0xa3204a), dangerSoft = hex(0xf8dce4)
        )

        val jarvis = CCMBPalette(
            bg = hex(0x0c1420), card = hex(0x121c2b), surface = hex(0x162337), surface2 = hex(0x1c2d44),
            text = hex(0xe3edf7), text2 = hex(0xb3c4d6), muted = hex(0x8da2b8),
            border = hex(0x20324a), border2 = hex(0x2d4663),
            accent = hex(0x4cc2e6), accentStrong = hex(0x8fdcf3), accentSoft = hex(0x12324a), onAccent = hex(0x04202b),
            warn = hex(0xf0b45c), warnSoft = hex(0x3a2d16), warnInk = hex(0xf4cf94),
            danger = hex(0xf28b82), dangerSoft = hex(0x3d2126)
        )

        val ultron = CCMBPalette(
            bg = hex(0x121316), card = hex(0x1a1c20), surface = hex(0x202328), surface2 = hex(0x272a30),
            text = hex(0xe6e7ea), text2 = hex(0xb8bbc2), muted = hex(0x8e929b),
            border = hex(0x2b2e34), border2 = hex(0x3b3f47),
            accent = hex(0xf2566a), accentStrong = hex(0xff8a95), accentSoft = hex(0x3a1a20), onAccent = hex(0x1a0508),
            warn = hex(0xe8a24f), warnSoft = hex(0x36291a), warnInk = hex(0xf2c27f),
            danger = hex(0xff9a9a), dangerSoft = hex(0x3e1f22)
        )
    }
}

val LocalCCMBPalette = compositionLocalOf { CCMBPalette.light }

enum class CCMBAppearance(val rawValue: String, val displayName: String) {
    LIGHT("light", "라이트"),
    FRIDAY("friday", "프라이데이"),
    JARVIS("jarvis", "자비스"),
    ULTRON("ultron", "울트론");

    val isDark: Boolean
        get() = this == JARVIS || this == ULTRON

    val palette: CCMBPalette
        get() = when (this) {
            LIGHT -> CCMBPalette.light
            FRIDAY -> CCMBPalette.friday
            JARVIS -> CCMBPalette.jarvis
            ULTRON -> CCMBPalette.ultron
        }

    val next: CCMBAppearance
        get() {
            val list = entries
            val idx = list.indexOf(this)
            return list[(idx + 1) % list.size]
        }

    companion object {
        fun migrated(from: String?, systemIsDark: Boolean): CCMBAppearance {
            return when (from) {
                "light", "daylight", "medium" -> LIGHT
                "friday", "casual", "vivid" -> FRIDAY
                "jarvis", "night", "dark" -> JARVIS
                "ultron" -> ULTRON
                else -> if (systemIsDark) JARVIS else LIGHT
            }
        }
    }
}

object CCMBTheme {
    val signalRed: Color = Color(0xFFE41E25)
    val lowRemainingThreshold: Double = 10.0

    val codexBrand: Color = Color(0xFF10A37F)
    val codexIconDark: Color = Color(0xFF02172C)
    val codexIconTeal: Color = Color(0xFF1FDB9E)

    val claudeCoral: Color = Color(0xFFFA6032)
    val claudeFable: Color = Color(0xFF50659E)

    val geminiBlue: Color = Color(0xFF4285F4)
    val geminiRed: Color = Color(0xFFEA4335)
    val geminiYellow: Color = Color(0xFFFBBC05)
    val geminiGreen: Color = Color(0xFF34A853)

    fun serviceTint(service: Service, windowId: String? = null): Color = when (service) {
        Service.CODEX -> codexBrand
        Service.CLAUDE -> when (windowId) {
            "fableWeekly" -> claudeFable
            else -> claudeCoral
        }
        Service.GEMINI -> geminiBlue
        Service.GEMINI2 -> geminiRed
        Service.GEMINI3 -> geminiYellow
        Service.GROK -> Color.Gray
    }

    fun gaugeTint(remainingPercent: Double?, palette: CCMBPalette): Color {
        if (remainingPercent == null) return palette.muted
        return if (remainingPercent < lowRemainingThreshold) palette.danger else palette.text
    }
}
