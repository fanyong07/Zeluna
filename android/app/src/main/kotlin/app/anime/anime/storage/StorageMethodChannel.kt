package app.anime.anime.storage

import android.os.StatFs
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class StorageMethodChannel(messenger: BinaryMessenger) : AutoCloseable {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)

    init {
        channel.setMethodCallHandler(::onMethodCall)
    }

    override fun close() {
        channel.setMethodCallHandler(null)
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "getAvailableBytes") {
            result.notImplemented()
            return
        }
        val path = call.argument<String>("path")
        if (path.isNullOrBlank()) {
            result.error("storage_invalid_path", "A storage path is required.", null)
            return
        }
        try {
            val canonicalPath = File(path).canonicalPath
            result.success(StatFs(canonicalPath).availableBytes)
        } catch (_: Throwable) {
            result.error("storage_query_failed", "Available storage could not be read.", null)
        }
    }

    companion object {
        const val CHANNEL_NAME = "app.anime.anime/storage"
    }
}
