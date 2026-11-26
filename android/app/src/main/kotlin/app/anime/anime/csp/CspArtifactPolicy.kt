package app.anime.anime.csp

import java.io.File
import java.io.FileInputStream
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Locale
import java.util.zip.ZipException
import java.util.zip.ZipFile

data class CspArtifactSpec(
    val id: String,
    val url: String,
    val md5: String,
    val sha256: String,
    val maxDownloadBytes: Long,
    val allowedApis: Set<String>,
)

data class CspArtifactDigests(
    val md5: String,
    val sha256: String,
    val bytes: Long,
)

/**
 * Security policy for the first CSP compatibility tranche.
 *
 * The executable URL and both digests are deliberately compiled into the app.
 * Imported TVBox data cannot widen this allowlist.
 */
object CspArtifactPolicy {
    const val GAO_PACKAGE_ID = "gao-fan-8213bb0"
    const val QIST_PACKAGE_ID = "qist-custom-f1ec5de"
    const val MAX_UNCOMPRESSED_BYTES = 8L * 1024L * 1024L
    const val MAX_ARCHIVE_ENTRIES = 16

    private val gaoAllowedApis = setOf(
        "csp_AList",
        "csp_Alllive",
        "csp_Anime1",
        "csp_AppSx",
        "csp_AppTT",
        "csp_Auete",
        "csp_Bili",
        "csp_Bttwoo",
        "csp_Djtt",
        "csp_Dm84",
        "csp_DouDou",
        "csp_FirstAid",
        "csp_Jpys",
        "csp_kanqiu926",
        "csp_Kekys",
        "csp_KkSs",
        "csp_Libvio",
        "csp_LiteApple",
        "csp_MIPanSo",
        "csp_NanGua",
        "csp_NewCz",
        "csp_Nmyswv",
        "csp_PanSearch",
        "csp_PanSso",
        "csp_Push",
        "csp_SixV",
        "csp_WoGG",
        "csp_YGP",
        "csp_YiSo",
        "csp_Ysj",
        "csp_Zxzj",
    )

    private val qistAllowedApis = setOf(
        "csp_AList",
        "csp_Bili",
        "csp_Dm84",
        "csp_Douban",
        "csp_Jianpian",
        "csp_JustLive",
        "csp_Kanqiu",
        "csp_Kugou",
        "csp_Local",
        "csp_Market",
        "csp_PanSearch",
        "csp_PanSou",
        "csp_Push",
        "csp_Star",
        "csp_UpYun",
        "csp_WebDAV",
        "csp_Wogg",
        "csp_Xb6v",
        "csp_XiaoZhiTiao",
        "csp_XPathMacFilter",
        "csp_YiSo",
        "csp_Ysj",
        "csp_Zhaozy",
    )

    val gaoArtifact = CspArtifactSpec(
        id = GAO_PACKAGE_ID,
        url = "https://raw.githubusercontent.com/gaotianliuyun/gao/" +
            "8213bb046f4dce746b5f2ddcddb13a336d0b0d60/jar/fan.txt",
        md5 = "6c4ab3a9d232164c75534f9060506ee5",
        sha256 = "67a8de7a23bd0be86ded0ea99cabc42209f9194c912b9ff8151e4c18d1d3ab7c",
        maxDownloadBytes = 2L * 1024L * 1024L,
        allowedApis = gaoAllowedApis,
    )

    val qistArtifact = CspArtifactSpec(
        id = QIST_PACKAGE_ID,
        url = "https://raw.githubusercontent.com/qist/tvbox/" +
            "f1ec5de1cb89fc0accfa2998dc5eccd5892efb1c/jar/custom_spider.jar",
        md5 = "41c87635d7592069884a5dafa12acabe",
        sha256 = "646c5449e06bceea84eac4f42341a887187c4f09cfcb038820418719a898669f",
        maxDownloadBytes = 2L * 1024L * 1024L,
        allowedApis = qistAllowedApis,
    )

    val pinnedArtifacts: List<CspArtifactSpec> = listOf(gaoArtifact, qistArtifact)

    val artifactsByMd5: Map<String, CspArtifactSpec> = pinnedArtifacts.associateBy { it.md5 }

    fun requireKnownArtifact(spiderMd5: String): CspArtifactSpec {
        val normalized = spiderMd5.trim().lowercase(Locale.ROOT)
        if (!normalized.matches(Regex("^[0-9a-f]{32}$"))) {
            throw CspBridgeException(
                "csp_artifact_not_allowed",
                "The CSP package digest is not recognized.",
            )
        }
        return artifactsByMd5[normalized] ?: throw CspBridgeException(
            "csp_artifact_not_allowed",
            "This CSP package is not in the audited allowlist.",
        )
    }

    fun allowedApiNames(spiderMd5: String): Set<String> =
        requireKnownArtifact(spiderMd5).allowedApis

    fun requireAllowedApi(spiderMd5: String, api: String): String {
        val spec = requireKnownArtifact(spiderMd5)
        val normalized = api.trim()
        if (!spec.allowedApis.contains(normalized)) {
            throw CspBridgeException(
                "csp_api_not_allowed",
                "This CSP class is not in the audited package allowlist.",
            )
        }
        return normalized
    }

    fun requirePinnedArtifact(spec: CspArtifactSpec) {
        val pinned = requireKnownArtifact(spec.md5)
        val uri = runCatching { java.net.URI(spec.url) }.getOrNull()
        if (spec != pinned ||
            uri?.scheme != "https" ||
            uri.host != "raw.githubusercontent.com" ||
            !spec.md5.matches(Regex("^[0-9a-f]{32}$")) ||
            !spec.sha256.matches(Regex("^[0-9a-f]{64}$"))
        ) {
            throw CspBridgeException(
                "csp_artifact_not_allowed",
                "Only an audited, pinned CSP artifact is allowed.",
            )
        }
    }

    fun verifyArtifact(file: File, spec: CspArtifactSpec): CspArtifactDigests {
        requirePinnedArtifact(spec)
        if (!file.isFile) {
            throw CspBridgeException("csp_artifact_missing", "The CSP artifact is missing.")
        }
        if (file.length() <= 0L || file.length() > spec.maxDownloadBytes) {
            throw CspBridgeException(
                "csp_artifact_size_invalid",
                "The CSP artifact size is outside the allowed range.",
            )
        }
        val digests = computeDigests(file, spec.maxDownloadBytes)
        if (!secureEquals(digests.md5, spec.md5) ||
            !secureEquals(digests.sha256, spec.sha256)
        ) {
            throw CspBridgeException(
                "csp_artifact_hash_mismatch",
                "The CSP artifact failed MD5/SHA-256 verification.",
            )
        }
        validatePureDexArchive(file)
        return digests
    }

    internal fun computeDigests(file: File, maxBytes: Long): CspArtifactDigests {
        val md5 = MessageDigest.getInstance("MD5")
        val sha256 = MessageDigest.getInstance("SHA-256")
        var count = 0L
        FileInputStream(file).use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                count += read
                if (count > maxBytes) {
                    throw CspBridgeException(
                        "csp_artifact_too_large",
                        "The CSP artifact exceeds the download limit.",
                    )
                }
                md5.update(buffer, 0, read)
                sha256.update(buffer, 0, read)
            }
        }
        return CspArtifactDigests(
            md5 = md5.digest().toHex(),
            sha256 = sha256.digest().toHex(),
            bytes = count,
        )
    }

    internal fun validatePureDexArchive(file: File) {
        try {
            ZipFile(file).use { archive ->
                val entries = archive.entries().asSequence().toList()
                if (entries.size > MAX_ARCHIVE_ENTRIES) {
                    throw CspBridgeException(
                        "csp_artifact_archive_invalid",
                        "The CSP artifact contains too many entries.",
                    )
                }
                var dexCount = 0
                var totalUncompressed = 0L
                for (entry in entries) {
                    if (entry.isDirectory) continue
                    val name = entry.name.replace('\\', '/')
                    val lower = name.lowercase(Locale.ROOT)
                    if (name.startsWith('/') || name.split('/').any { it == ".." }) {
                        throw CspBridgeException(
                            "csp_artifact_archive_invalid",
                            "The CSP artifact contains an unsafe entry path.",
                        )
                    }
                    if (lower.endsWith(".so") ||
                        lower.endsWith(".dll") ||
                        lower.endsWith(".exe") ||
                        lower.endsWith(".guard")
                    ) {
                        throw CspBridgeException(
                            "csp_native_code_rejected",
                            "Native or Guard payloads are not allowed in this CSP tranche.",
                        )
                    }
                    if (lower.matches(Regex("classes\\d*\\.dex")) && lower != "classes.dex") {
                        throw CspBridgeException(
                            "csp_artifact_archive_invalid",
                            "Only a single classes.dex payload is allowed.",
                        )
                    }

                    archive.getInputStream(entry).use { input ->
                        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                        var prefix = ByteArray(0)
                        while (true) {
                            val read = input.read(buffer)
                            if (read < 0) break
                            totalUncompressed += read
                            if (totalUncompressed > MAX_UNCOMPRESSED_BYTES) {
                                throw CspBridgeException(
                                    "csp_artifact_archive_invalid",
                                    "The CSP artifact expands beyond the allowed limit.",
                                )
                            }
                            if (lower == "classes.dex" && prefix.size < 8) {
                                val needed = minOf(8 - prefix.size, read)
                                prefix += buffer.copyOfRange(0, needed)
                            }
                        }
                        if (lower == "classes.dex") {
                            dexCount++
                            val dexMagic = prefix.size >= 8 &&
                                prefix[0] == 'd'.code.toByte() &&
                                prefix[1] == 'e'.code.toByte() &&
                                prefix[2] == 'x'.code.toByte() &&
                                prefix[3] == '\n'.code.toByte() &&
                                prefix[7] == 0.toByte()
                            if (!dexMagic) {
                                throw CspBridgeException(
                                    "csp_artifact_archive_invalid",
                                    "The classes.dex header is invalid.",
                                )
                            }
                        }
                    }
                }
                if (dexCount != 1) {
                    throw CspBridgeException(
                        "csp_artifact_archive_invalid",
                        "The CSP artifact must contain exactly one classes.dex.",
                    )
                }
            }
        } catch (error: CspBridgeException) {
            throw error
        } catch (error: ZipException) {
            throw CspBridgeException(
                "csp_artifact_archive_invalid",
                "The CSP artifact is not a valid DEX archive.",
                error,
            )
        }
    }

    private fun secureEquals(actual: String, expected: String): Boolean =
        MessageDigest.isEqual(
            actual.toByteArray(StandardCharsets.US_ASCII),
            expected.toByteArray(StandardCharsets.US_ASCII),
        )

    private fun ByteArray.toHex(): String = joinToString(separator = "") { byte ->
        "%02x".format(Locale.ROOT, byte.toInt() and 0xff)
    }
}
