package app.anime.anime.csp

import android.content.Context
import android.system.Os
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient
import okhttp3.Request

data class PreparedCspArtifact(
    val file: File,
    val fromCache: Boolean,
    val bytes: Long,
)

class CspArtifactStore(
    context: Context,
) {
    private val appContext = context.applicationContext
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .callTimeout(20, TimeUnit.SECONDS)
        .followRedirects(false)
        .followSslRedirects(false)
        .build()

    @Synchronized
    fun prepare(spiderMd5: String): PreparedCspArtifact {
        val spec = CspArtifactPolicy.requireKnownArtifact(spiderMd5)
        CspArtifactPolicy.requirePinnedArtifact(spec)
        val directory = trustedCacheDirectory()
        val artifact = File(directory, "${spec.id}-${spec.sha256.take(16)}.jar")

        if (artifact.isFile) {
            try {
                val verified = CspArtifactPolicy.verifyArtifact(artifact, spec)
                if (!artifact.setReadOnly()) {
                    throw CspBridgeException(
                        "csp_cache_permissions_failed",
                        "The verified CSP cache could not be made read-only.",
                    )
                }
                return PreparedCspArtifact(artifact, fromCache = true, bytes = verified.bytes)
            } catch (_: CspBridgeException) {
                // Keep the suspect cache in place until a fully verified replacement is ready.
            }
        }

        val temporary = File(directory, ".${spec.id}-${UUID.randomUUID()}.part")
        try {
            downloadTo(temporary, spec)
            val verified = CspArtifactPolicy.verifyArtifact(temporary, spec)
            if (!temporary.setReadOnly()) {
                throw CspBridgeException(
                    "csp_cache_permissions_failed",
                    "The verified CSP download could not be made read-only.",
                )
            }

            // temp and destination are in the same private directory. POSIX rename replaces
            // the destination atomically, so a partial artifact is never observable.
            Os.rename(temporary.absolutePath, artifact.absolutePath)
            if (!artifact.setReadOnly()) {
                throw CspBridgeException(
                    "csp_cache_permissions_failed",
                    "The CSP cache could not be made read-only.",
                )
            }
            val finalVerification = CspArtifactPolicy.verifyArtifact(artifact, spec)
            return PreparedCspArtifact(
                artifact,
                fromCache = false,
                bytes = finalVerification.bytes,
            )
        } catch (error: CspBridgeException) {
            throw error
        } catch (error: Exception) {
            throw CspBridgeException(
                "csp_artifact_download_failed",
                "The pinned CSP artifact could not be prepared.",
                error,
            )
        } finally {
            if (temporary.exists()) temporary.delete()
        }
    }

    fun close() {
        client.dispatcher.executorService.shutdown()
        client.connectionPool.evictAll()
    }

    private fun downloadTo(target: File, spec: CspArtifactSpec) {
        val request = Request.Builder()
            .url(spec.url)
            .header("Accept", "application/octet-stream")
            .header("User-Agent", "Zeluna-CSP/1.0")
            .get()
            .build()
        client.newCall(request).execute().use { response ->
            if (response.code != 200 || response.request.url.toString() != spec.url) {
                throw CspBridgeException(
                    "csp_artifact_download_failed",
                    "The pinned CSP server returned an unexpected response.",
                )
            }
            val body = response.body ?: throw CspBridgeException(
                "csp_artifact_download_failed",
                "The pinned CSP server returned an empty response.",
            )
            val contentLength = body.contentLength()
            if (contentLength <= 0L || contentLength > spec.maxDownloadBytes) {
                throw CspBridgeException(
                    "csp_artifact_size_invalid",
                    "The CSP download size is outside the allowed range.",
                )
            }

            body.byteStream().use { input ->
                FileOutputStream(target).use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var written = 0L
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        written += read
                        if (written > spec.maxDownloadBytes) {
                            throw CspBridgeException(
                                "csp_artifact_too_large",
                                "The CSP download exceeds the allowed limit.",
                            )
                        }
                        output.write(buffer, 0, read)
                    }
                    output.flush()
                    output.fd.sync()
                    if (written != contentLength) {
                        throw CspBridgeException(
                            "csp_artifact_download_failed",
                            "The CSP download ended before its declared size.",
                        )
                    }
                }
            }
        }
    }

    private fun trustedCacheDirectory(): File {
        val codeCache = appContext.codeCacheDir.canonicalFile
        val directory = File(codeCache, "csp").canonicalFile
        val expectedPrefix = codeCache.path + File.separator
        if (!directory.path.startsWith(expectedPrefix)) {
            throw CspBridgeException(
                "csp_cache_path_invalid",
                "The CSP cache path is outside the app code cache.",
            )
        }
        if ((!directory.exists() && !directory.mkdirs()) || !directory.isDirectory) {
            throw CspBridgeException(
                "csp_cache_unavailable",
                "The CSP code cache is unavailable.",
            )
        }
        return directory
    }
}
