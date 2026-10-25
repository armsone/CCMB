package com.armsone.ccmb.model

enum class Service(val rawValue: String) {
    CODEX("codex"),
    CLAUDE("claude"),
    GEMINI("gemini"),
    GEMINI2("gemini2"),
    GEMINI3("gemini3"),
    GROK("grok");

    val displayName: String
        get() = when (this) {
            CODEX -> "Codex"
            CLAUDE -> "Claude"
            GEMINI, GEMINI2, GEMINI3 -> "Gemini"
            GROK -> "Grok"
        }

    val accountTag: String?
        get() = when (this) {
            GEMINI -> "본계정"
            GEMINI2 -> "부계정"
            GEMINI3 -> "세 번째 계정"
            else -> null
        }

    val isGemini: Boolean
        get() = this == GEMINI || this == GEMINI2 || this == GEMINI3

    companion object {
        fun fromRaw(raw: String): Service? = entries.firstOrNull { it.rawValue == raw }
    }
}
