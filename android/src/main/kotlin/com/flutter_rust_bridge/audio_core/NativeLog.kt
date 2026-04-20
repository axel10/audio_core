package com.flutter_rust_bridge.audio_core

import android.content.Context
import android.util.Log
import java.io.File
import java.util.concurrent.Executors

object NativeLog {
    private const val FILE_NAME = "android.log"
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "AudioCoreNativeLog").apply {
            isDaemon = true
        }
    }

    @Volatile
    private var logFile: File? = null

    fun init(context: Context) {
        if (logFile != null) return
        synchronized(this) {
            if (logFile != null) return
            val dir = File(context.filesDir, "audio_core_logs")
            if (!dir.exists()) {
                dir.mkdirs()
            }
            logFile = File(dir, FILE_NAME)
        }
    }

    fun d(tag: String, message: String) = log(Log.DEBUG, tag, message)
    fun v(tag: String, message: String) = log(Log.VERBOSE, tag, message)
    fun w(tag: String, message: String) = log(Log.WARN, tag, message)
    fun e(tag: String, message: String) = log(Log.ERROR, tag, message)
    fun e(tag: String, message: String, throwable: Throwable) {
        log(Log.ERROR, tag, message, throwable)
    }

    private fun log(
        priority: Int,
        tag: String,
        message: String,
        throwable: Throwable? = null,
    ) {
        when (priority) {
            Log.VERBOSE -> Log.v(tag, message, throwable)
            Log.DEBUG -> Log.d(tag, message, throwable)
            Log.INFO -> Log.i(tag, message, throwable)
            Log.WARN -> Log.w(tag, message, throwable)
            else -> Log.e(tag, message, throwable)
        }

        val file = logFile ?: return
        val timestamp = System.currentTimeMillis().toString()
        val line = buildString {
            append('[')
            append(timestamp)
            append("][")
            append(priorityLabel(priority))
            append('/')
            append(tag)
            append("] ")
            append(message)
            if (throwable != null) {
                append(" | ")
                append(throwable.stackTraceToString())
            }
        }

        executor.execute {
            runCatching {
                file.appendText(line + System.lineSeparator())
            }
        }
    }

    private fun priorityLabel(priority: Int): String = when (priority) {
        Log.VERBOSE -> "V"
        Log.DEBUG -> "D"
        Log.INFO -> "I"
        Log.WARN -> "W"
        else -> "E"
    }
}
