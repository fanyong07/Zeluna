package com.github.catvod.crawler;

import android.util.Log;

/** Minimal logging ABI required by the pinned gao Spider package. */
public final class SpiderDebug {

    private static final String TAG = "CspSpider";

    private SpiderDebug() {
    }

    public static void log(Throwable throwable) {
        if (throwable != null) Log.w(TAG, throwable.getClass().getSimpleName());
    }

    public static void log(String message) {
        // Spider output can contain cookies, tokens, or signed media URLs.
        // Preserve the ABI while deliberately keeping release logs empty.
    }

    public static void log(String tag, String message, Object... args) {
        // Intentionally no-op; see log(String).
    }
}
