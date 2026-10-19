package dev.davidv.translator;

// Public API of Offline Translator (dev.davidv.translator). Kept in that
// package so the generated binder matches the other app.
enum ErrorType {
    COULD_NOT_DETECT_LANGUAGE,
    DETECTED_BUT_UNAVAILABLE,
    UNEXPECTED,
}
