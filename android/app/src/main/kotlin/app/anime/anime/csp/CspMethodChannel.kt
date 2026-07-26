package app.anime.anime.csp

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class CspMethodChannel(
    context: Context,
    messenger: BinaryMessenger,
) : AutoCloseable {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val executor = CspExecutor(context)
    private val commandExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "zeluna-csp-channel").apply { isDaemon = true }
    }
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var closed = false

    init {
        channel.setMethodCallHandler(::onMethodCall)
    }

    override fun close() {
        if (closed) return
        closed = true
        channel.setMethodCallHandler(null)
        commandExecutor.execute { executor.close() }
        commandExecutor.shutdown()
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (closed) {
            result.error("csp_closed", "The CSP bridge is closed.", null)
            return
        }
        commandExecutor.execute {
            try {
                val response = dispatch(call)
                mainHandler.post { result.success(response) }
            } catch (error: CspBridgeException) {
                mainHandler.post { result.error(error.code, error.message, null) }
            } catch (_: Throwable) {
                mainHandler.post {
                    result.error("csp_internal", "The Android CSP bridge failed.", null)
                }
            }
        }
    }

    private fun dispatch(call: MethodCall): Any = when (call.method) {
        "getCapabilities" -> executor.capabilities()
        "prepare" -> {
            val args = call.argumentMap()
            executor.prepare(args.requiredString("spiderMd5")).let { prepared ->
                mapOf(
                    "packageId" to prepared.packageId,
                    "md5" to prepared.md5,
                    "sha256" to prepared.sha256,
                    "bytes" to prepared.bytes,
                    "fromCache" to prepared.fromCache,
                )
            }
        }
        "initialize" -> {
            val args = call.argumentMap()
            executor.initialize(
                spiderMd5 = args.requiredString("spiderMd5"),
                siteKey = args.requiredString("siteKey"),
                api = args.requiredString("api"),
                ext = args.optionalString("ext"),
            )
            mapOf("ready" to true)
        }
        "searchContent" -> {
            val args = call.argumentMap()
            mapOf(
                "json" to executor.searchContent(
                    spiderMd5 = args.requiredString("spiderMd5"),
                    siteKey = args.requiredString("siteKey"),
                    api = args.requiredString("api"),
                    keyword = args.requiredString("keyword"),
                    quick = args.optionalBoolean("quick"),
                    page = args.nullableString("page"),
                ),
            )
        }
        "detailContent" -> {
            val args = call.argumentMap()
            mapOf(
                "json" to executor.detailContent(
                    spiderMd5 = args.requiredString("spiderMd5"),
                    siteKey = args.requiredString("siteKey"),
                    api = args.requiredString("api"),
                    ids = args.requiredStringList("ids"),
                ),
            )
        }
        "playerContent" -> {
            val args = call.argumentMap()
            mapOf(
                "json" to executor.playerContent(
                    spiderMd5 = args.requiredString("spiderMd5"),
                    siteKey = args.requiredString("siteKey"),
                    api = args.requiredString("api"),
                    flag = args.optionalString("flag"),
                    id = args.requiredString("id"),
                    vipFlags = args.optionalStringList("vipFlags"),
                ),
            )
        }
        "destroy" -> {
            val args = call.argumentMap()
            mapOf(
                "destroyed" to executor.destroy(
                    spiderMd5 = args.requiredString("spiderMd5"),
                    siteKey = args.requiredString("siteKey"),
                    api = args.requiredString("api"),
                ),
            )
        }
        "destroyAll" -> {
            executor.destroyAll()
            mapOf("destroyed" to true)
        }
        else -> throw CspBridgeException(
            "csp_method_not_supported",
            "The requested CSP bridge method is not supported.",
        )
    }

    private fun MethodCall.argumentMap(): Map<*, *> =
        arguments as? Map<*, *> ?: emptyMap<String, Any?>()

    private fun Map<*, *>.requiredString(key: String): String =
        (this[key] as? String)?.takeIf { it.isNotBlank() } ?: throw CspBridgeException(
            "csp_invalid_arguments",
            "The CSP $key argument is required.",
        )

    private fun Map<*, *>.optionalString(key: String): String = this[key] as? String ?: ""

    private fun Map<*, *>.nullableString(key: String): String? = this[key] as? String

    private fun Map<*, *>.optionalBoolean(key: String): Boolean = this[key] as? Boolean ?: false

    private fun Map<*, *>.requiredStringList(key: String): List<String> {
        val values = this[key] as? List<*> ?: throw CspBridgeException(
            "csp_invalid_arguments",
            "The CSP $key argument is required.",
        )
        if (values.any { it !is String }) {
            throw CspBridgeException("csp_invalid_arguments", "The CSP $key list is invalid.")
        }
        return values.filterIsInstance<String>()
    }

    private fun Map<*, *>.optionalStringList(key: String): List<String> {
        val values = this[key] as? List<*> ?: return emptyList()
        if (values.any { it !is String }) {
            throw CspBridgeException("csp_invalid_arguments", "The CSP $key list is invalid.")
        }
        return values.filterIsInstance<String>()
    }

    companion object {
        const val CHANNEL_NAME = "app.anime.anime/csp"
    }
}
