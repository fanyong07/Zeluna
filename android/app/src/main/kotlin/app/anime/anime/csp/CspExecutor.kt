package app.anime.anime.csp

import android.content.Context
import dalvik.system.DexClassLoader
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Modifier
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

data class CspExecutorPreparation(
    val packageId: String,
    val md5: String,
    val sha256: String,
    val bytes: Long,
    val fromCache: Boolean,
)

class CspExecutor(context: Context) : AutoCloseable {
    private data class SpiderHolder(
        val instance: Any,
        val packageId: String,
        val api: String,
        val extHash: String,
    )

    private val appContext = context.applicationContext
    private val artifactStore = CspArtifactStore(appContext)
    private val invocationPool: ExecutorService = Executors.newFixedThreadPool(2) { runnable ->
        Thread(runnable, "zeluna-csp-worker").apply { isDaemon = true }
    }
    private val holders = ConcurrentHashMap<String, SpiderHolder>()
    private val classLoaders = ConcurrentHashMap<String, DexClassLoader>()
    private val loaderLock = Any()

    @Volatile
    private var closed = false

    fun capabilities(): Map<String, Any> = mapOf(
        "packages" to CspArtifactPolicy.pinnedArtifacts.map { spec ->
            mapOf(
                "packageId" to spec.id,
                "artifactUrl" to spec.url,
                "md5" to spec.md5,
                "sha256" to spec.sha256,
                "allowedApis" to spec.allowedApis.sorted(),
            )
        },
        "supportsGuard" to false,
        "supportsDianshi" to false,
    )

    fun prepare(spiderMd5: String): CspExecutorPreparation {
        ensureOpen()
        val spec = CspArtifactPolicy.requireKnownArtifact(spiderMd5)
        val prepared = ensureLoader(spec)
        return CspExecutorPreparation(
            packageId = spec.id,
            md5 = spec.md5,
            sha256 = spec.sha256,
            bytes = prepared.bytes,
            fromCache = prepared.fromCache,
        )
    }

    fun initialize(spiderMd5: String, siteKey: String, api: String, ext: String) {
        ensureOpen()
        val spec = CspArtifactPolicy.requireKnownArtifact(spiderMd5)
        ensureLoader(spec)
        invokeWithTimeout("initialize", INIT_TIMEOUT_SECONDS) {
            getOrCreateHolder(spec, siteKey, api, ext)
            Unit
        }
    }

    fun searchContent(
        spiderMd5: String,
        siteKey: String,
        api: String,
        keyword: String,
        quick: Boolean,
        page: String?,
    ): String {
        val safeKeyword = requireText("keyword", keyword, MAX_KEYWORD_CHARS)
        val holder = requireHolder(spiderMd5, siteKey, api)
        return invokeWithTimeout("searchContent") {
            val result = if (!page.isNullOrBlank() && page != "1") {
                invoke(
                    holder,
                    "searchContent",
                    arrayOf(String::class.java, Boolean::class.javaPrimitiveType!!, String::class.java),
                    arrayOf(safeKeyword, quick, requireText("page", page, MAX_PAGE_CHARS)),
                )
            } else {
                invoke(
                    holder,
                    "searchContent",
                    arrayOf(String::class.java, Boolean::class.javaPrimitiveType!!),
                    arrayOf(safeKeyword, quick),
                )
            }
            requireJsonString(result, "searchContent")
        }
    }

    fun detailContent(
        spiderMd5: String,
        siteKey: String,
        api: String,
        ids: List<String>,
    ): String {
        val safeIds = requireTextList("ids", ids, MAX_IDS, MAX_ID_CHARS)
        val holder = requireHolder(spiderMd5, siteKey, api)
        return invokeWithTimeout("detailContent") {
            requireJsonString(
                invoke(
                    holder,
                    "detailContent",
                    arrayOf(List::class.java),
                    arrayOf(safeIds),
                ),
                "detailContent",
            )
        }
    }

    fun playerContent(
        spiderMd5: String,
        siteKey: String,
        api: String,
        flag: String,
        id: String,
        vipFlags: List<String>,
    ): String {
        val safeFlag = requireText("flag", flag, MAX_FLAG_CHARS, allowEmpty = true)
        val safeId = requireText("id", id, MAX_ID_CHARS)
        val safeVipFlags = requireTextList(
            "vipFlags",
            vipFlags,
            MAX_VIP_FLAGS,
            MAX_FLAG_CHARS,
            allowEmptyList = true,
            allowEmptyItems = false,
        )
        val holder = requireHolder(spiderMd5, siteKey, api)
        return invokeWithTimeout("playerContent") {
            requireJsonString(
                invoke(
                    holder,
                    "playerContent",
                    arrayOf(String::class.java, String::class.java, List::class.java),
                    arrayOf(safeFlag, safeId, safeVipFlags),
                ),
                "playerContent",
            )
        }
    }

    fun destroy(spiderMd5: String, siteKey: String, api: String): Boolean {
        val spec = CspArtifactPolicy.requireKnownArtifact(spiderMd5)
        val key = holderKey(
            spec.id,
            requireSiteKey(siteKey),
            CspArtifactPolicy.requireAllowedApi(spec.md5, api),
        )
        val holder = holders.remove(key) ?: return false
        runCatching {
            invokeWithTimeout("destroy", DESTROY_TIMEOUT_SECONDS) {
                invoke(holder, "destroy", emptyArray(), emptyArray())
            }
        }
        return true
    }

    fun destroyAll() {
        val current = holders.values.toList()
        holders.clear()
        current.forEach { holder ->
            runCatching {
                invokeWithTimeout("destroy", DESTROY_TIMEOUT_SECONDS) {
                    invoke(holder, "destroy", emptyArray(), emptyArray())
                }
            }
        }
    }

    override fun close() {
        if (closed) return
        destroyAll()
        closed = true
        invocationPool.shutdownNow()
        artifactStore.close()
        classLoaders.clear()
    }

    private fun ensureLoader(spec: CspArtifactSpec): PreparedCspArtifact {
        synchronized(loaderLock) {
            ensureOpen()
            classLoaders[spec.id]?.let {
                val cached = artifactStore.prepare(spec.md5)
                CspArtifactPolicy.verifyArtifact(cached.file, spec)
                return cached
            }

            val prepared = artifactStore.prepare(spec.md5)
            // Verify immediately before handing the path to ART. The app-private,
            // read-only file closes the verification-to-load race for this process.
            CspArtifactPolicy.verifyArtifact(prepared.file, spec)
            val optimizedDirectory = appContext.codeCacheDir.resolve("csp/optimized/${spec.id}")
            if ((!optimizedDirectory.exists() && !optimizedDirectory.mkdirs()) ||
                !optimizedDirectory.isDirectory
            ) {
                throw CspBridgeException(
                    "csp_cache_unavailable",
                    "The CSP optimized code cache is unavailable.",
                )
            }
            val loader = DexClassLoader(
                prepared.file.absolutePath,
                optimizedDirectory.absolutePath,
                null,
                appContext.classLoader,
            )
            invokeWithTimeout("package init", INIT_TIMEOUT_SECONDS) {
                invokePackageInit(loader)
            }
            classLoaders[spec.id] = loader
            return prepared
        }
    }

    private fun invokePackageInit(loader: ClassLoader) {
        try {
            val initClass = loader.loadClass("com.github.catvod.spider.Init")
            val method = initClass.getMethod("init", Context::class.java)
            if (!Modifier.isStatic(method.modifiers)) {
                throw CspBridgeException(
                    "csp_class_contract_invalid",
                    "The pinned CSP package exposes an invalid init contract.",
                )
            }
            method.invoke(null, appContext)
        } catch (error: CspBridgeException) {
            throw error
        } catch (error: Throwable) {
            throw reflectionFailure("package init", error)
        }
    }

    private fun getOrCreateHolder(
        spec: CspArtifactSpec,
        siteKey: String,
        api: String,
        ext: String,
    ): SpiderHolder {
        val safeSiteKey = requireSiteKey(siteKey)
        val safeApi = CspArtifactPolicy.requireAllowedApi(spec.md5, api)
        if (ext.toByteArray(StandardCharsets.UTF_8).size > MAX_EXT_BYTES) {
            throw CspBridgeException("csp_invalid_arguments", "The CSP ext payload is too large.")
        }
        val key = holderKey(spec.id, safeSiteKey, safeApi)
        val extHash = sha256(ext)
        synchronized(holders) {
            val existing = holders[key]
            if (existing != null && existing.extHash == extHash) return existing
            if (existing != null) {
                runCatching { invoke(existing, "destroy", emptyArray(), emptyArray()) }
                holders.remove(key)
            }

            val loader = classLoaders[spec.id] ?: throw CspBridgeException(
                "csp_not_prepared",
                "The CSP artifact has not been prepared.",
            )
            try {
                val suffix = safeApi.removePrefix("csp_")
                val clazz = loader.loadClass("com.github.catvod.spider.$suffix")
                val instance = clazz.getDeclaredConstructor().newInstance()
                clazz.getField("siteKey").set(instance, safeSiteKey)
                val holder = SpiderHolder(instance, spec.id, safeApi, extHash)
                invoke(
                    holder,
                    "init",
                    arrayOf(Context::class.java, String::class.java),
                    arrayOf(appContext, ext),
                )
                holders[key] = holder
                return holder
            } catch (error: CspBridgeException) {
                throw error
            } catch (error: Throwable) {
                throw reflectionFailure("class initialization", error)
            }
        }
    }

    private fun requireHolder(spiderMd5: String, siteKey: String, api: String): SpiderHolder {
        ensureOpen()
        val spec = CspArtifactPolicy.requireKnownArtifact(spiderMd5)
        val safeSiteKey = requireSiteKey(siteKey)
        val safeApi = CspArtifactPolicy.requireAllowedApi(spec.md5, api)
        return holders[holderKey(spec.id, safeSiteKey, safeApi)] ?: throw CspBridgeException(
            "csp_not_initialized",
            "Initialize this CSP site before invoking it.",
        )
    }

    private fun invoke(
        holder: SpiderHolder,
        methodName: String,
        parameterTypes: Array<Class<*>>,
        arguments: Array<Any?>,
    ): Any? {
        try {
            val method = holder.instance.javaClass.getMethod(methodName, *parameterTypes)
            return method.invoke(holder.instance, *arguments)
        } catch (error: Throwable) {
            throw reflectionFailure(methodName, error)
        }
    }

    private fun requireJsonString(value: Any?, operation: String): String {
        val text = value as? String ?: throw CspBridgeException(
            "csp_result_invalid",
            "The CSP $operation result was not text.",
        )
        if (text.toByteArray(StandardCharsets.UTF_8).size > MAX_RESULT_BYTES) {
            throw CspBridgeException(
                "csp_result_too_large",
                "The CSP $operation result exceeded the allowed size.",
            )
        }
        return text
    }

    private fun <T> invokeWithTimeout(
        operation: String,
        timeoutSeconds: Long = INVOCATION_TIMEOUT_SECONDS,
        block: () -> T,
    ): T {
        ensureOpen()
        val future = invocationPool.submit(Callable(block))
        try {
            return future.get(timeoutSeconds, TimeUnit.SECONDS)
        } catch (error: TimeoutException) {
            future.cancel(true)
            throw CspBridgeException(
                "csp_timeout",
                "The CSP $operation call timed out.",
                error,
            )
        } catch (error: InterruptedException) {
            future.cancel(true)
            Thread.currentThread().interrupt()
            throw CspBridgeException(
                "csp_cancelled",
                "The CSP $operation call was cancelled.",
                error,
            )
        } catch (error: ExecutionException) {
            val cause = error.cause
            if (cause is CspBridgeException) throw cause
            throw reflectionFailure(operation, cause ?: error)
        }
    }

    private fun reflectionFailure(operation: String, error: Throwable): CspBridgeException {
        val cause = if (error is InvocationTargetException) error.targetException ?: error else error
        return CspBridgeException(
            "csp_invocation_failed",
            "The pinned CSP $operation call failed (${cause.javaClass.simpleName}).",
            cause,
        )
    }

    private fun requireSiteKey(value: String): String =
        requireText("siteKey", value, MAX_SITE_KEY_CHARS).also { siteKey ->
            if (siteKey.any(Char::isISOControl)) {
                throw CspBridgeException("csp_invalid_arguments", "The CSP siteKey is invalid.")
            }
        }

    private fun requireText(
        name: String,
        value: String,
        maxChars: Int,
        allowEmpty: Boolean = false,
    ): String {
        val trimmed = value.trim()
        if ((!allowEmpty && trimmed.isEmpty()) || trimmed.length > maxChars) {
            throw CspBridgeException("csp_invalid_arguments", "The CSP $name value is invalid.")
        }
        return trimmed
    }

    private fun requireTextList(
        name: String,
        values: List<String>,
        maxItems: Int,
        maxChars: Int,
        allowEmptyList: Boolean = false,
        allowEmptyItems: Boolean = false,
    ): List<String> {
        if ((!allowEmptyList && values.isEmpty()) || values.size > maxItems) {
            throw CspBridgeException("csp_invalid_arguments", "The CSP $name list is invalid.")
        }
        return values.map { requireText(name, it, maxChars, allowEmptyItems) }
    }

    private fun holderKey(packageId: String, siteKey: String, api: String): String =
        "$packageId\u0000$siteKey\u0000$api"

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(StandardCharsets.UTF_8))
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private fun ensureOpen() {
        if (closed) {
            throw CspBridgeException("csp_closed", "The CSP executor is closed.")
        }
    }

    companion object {
        private const val INIT_TIMEOUT_SECONDS = 20L
        private const val INVOCATION_TIMEOUT_SECONDS = 15L
        private const val DESTROY_TIMEOUT_SECONDS = 3L
        private const val MAX_RESULT_BYTES = 2 * 1024 * 1024
        private const val MAX_EXT_BYTES = 256 * 1024
        private const val MAX_SITE_KEY_CHARS = 160
        private const val MAX_KEYWORD_CHARS = 240
        private const val MAX_PAGE_CHARS = 16
        private const val MAX_ID_CHARS = 16 * 1024
        private const val MAX_FLAG_CHARS = 256
        private const val MAX_IDS = 20
        private const val MAX_VIP_FLAGS = 64
    }
}
