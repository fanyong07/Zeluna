package app.anime.anime.update

import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.zip.ZipFile

/** Stable, non-sensitive errors exposed over the update method channel. */
internal class AppUpdateException(val code: String) : Exception(messageFor(code)) {
    companion object {
        private fun messageFor(code: String): String = when (code) {
            "update_invalid_path" -> "The update file location is invalid."
            "update_hash_mismatch" -> "The update checksum does not match."
            "update_size_mismatch" -> "The update file size does not match."
            "update_package_mismatch" -> "The update package identity does not match."
            "update_version_mismatch" -> "The update version does not match."
            "update_not_newer" -> "The update is not newer than the installed app."
            "update_signature_mismatch" -> "The update signing certificates do not match."
            "update_incompatible" -> "The update package is incompatible with this device."
            "update_busy" -> "Another update verification is in progress."
            "update_closed" -> "The update bridge is closed."
            else -> "The Android update operation failed."
        }
    }
}

internal data class AppUpdateRequest(
    val path: String,
    val sha256: String,
    val bytes: Long,
    val versionName: String,
    val versionCode: Long,
)

internal data class AppUpdatePackage(
    val packageName: String,
    val versionName: String,
    val versionCode: Long,
    val minSdk: Int,
    // Encoded certificate bytes, not signing history or certificate subject names.
    val signerCertificates: Set<String>,
)

/** Android-independent rules, shared by verifyPackage and every installPackage call. */
internal object AppUpdatePolicy {
    const val MAX_APK_BYTES = 512L * 1024 * 1024
    private val sha256Pattern = Regex("^[0-9a-f]{64}$")

    fun parseRequest(arguments: Any?): AppUpdateRequest {
        val args = arguments as? Map<*, *> ?: fail("update_invalid_path")
        val path = args["path"] as? String ?: fail("update_invalid_path")
        val sha256 = args["sha256"] as? String ?: fail("update_hash_mismatch")
        val bytes = integer(args["bytes"]) ?: fail("update_size_mismatch")
        val versionName = args["versionName"] as? String ?: fail("update_version_mismatch")
        val versionCode = integer(args["versionCode"]) ?: fail("update_version_mismatch")
        if (path.isBlank() || '\u0000' in path) fail("update_invalid_path")
        if (!sha256Pattern.matches(sha256)) fail("update_hash_mismatch")
        if (bytes !in 1..MAX_APK_BYTES) fail("update_size_mismatch")
        if (versionName.isBlank() || versionCode <= 0) fail("update_version_mismatch")
        return AppUpdateRequest(path, sha256, bytes, versionName, versionCode)
    }

    /**
     * The caller passes a trusted canonical cache/app_updates directory. Comparing
     * absolute and canonical paths also rejects symlinks within that directory.
     * Android's cache parent may itself have an OS-managed alias, so normalize the
     * trusted parent before constructing this directory, never the supplied path.
     */
    fun requireApkFile(directory: File, path: String): File {
        try {
            val root = directory.absoluteFile
            if (root != root.canonicalFile || !root.isDirectory) fail("update_invalid_path")
            if (path.isBlank() || '\u0000' in path) fail("update_invalid_path")
            val segments = path.replace('\\', '/').split('/')
            if (segments.any { it == "." || it == ".." }) fail("update_invalid_path")
            val supplied = File(path)
            if (!supplied.isAbsolute) fail("update_invalid_path")
            val file = supplied.absoluteFile
            val canonical = file.canonicalFile
            if (file != canonical || !canonical.path.startsWith(root.path + File.separator)) {
                fail("update_invalid_path")
            }
            if (!file.name.endsWith(".apk") || !file.isFile || !file.canRead()) {
                fail("update_invalid_path")
            }
            return file
        } catch (_: IOException) {
            fail("update_invalid_path")
        } catch (_: SecurityException) {
            fail("update_invalid_path")
        }
    }

    fun verifyFile(file: File, request: AppUpdateRequest, checkActive: () -> Unit = {}) {
        if (request.bytes !in 1..MAX_APK_BYTES || file.length() != request.bytes) {
            fail("update_size_mismatch")
        }
        if (!sha256Pattern.matches(request.sha256)) fail("update_hash_mismatch")
        val digest = MessageDigest.getInstance("SHA-256")
        var total = 0L
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                checkActive()
                val count = input.read(buffer)
                if (count < 0) break
                total += count
                if (total > request.bytes || total > MAX_APK_BYTES) fail("update_size_mismatch")
                digest.update(buffer, 0, count)
            }
        }
        checkActive()
        if (total != request.bytes || file.length() != request.bytes) fail("update_size_mismatch")
        val expected = ByteArray(32) { index ->
            request.sha256.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
        if (!MessageDigest.isEqual(expected, digest.digest())) fail("update_hash_mismatch")
    }

    /** Inspect only ZIP entry names; never extract or load code from the APK. */
    fun verifyArchive(file: File, supportedAbis: Set<String>, checkActive: () -> Unit = {}) {
        try {
            ZipFile(file).use { archive ->
                if (archive.getEntry("AndroidManifest.xml")?.isDirectory != false) {
                    fail("update_incompatible")
                }
                val nativeAbis = mutableSetOf<String>()
                val entries = archive.entries()
                while (entries.hasMoreElements()) {
                    checkActive()
                    val entry = entries.nextElement()
                    val segments = entry.name.split('/')
                    if (!entry.isDirectory && segments.size == 3 &&
                        segments[0] == "lib" && segments[2].endsWith(".so")
                    ) {
                        nativeAbis.add(segments[1])
                    }
                }
                if (nativeAbis.isNotEmpty() && nativeAbis.intersect(supportedAbis).isEmpty()) {
                    fail("update_incompatible")
                }
            }
        } catch (_: IOException) {
            fail("update_incompatible")
        }
    }

    fun verifyPackage(
        request: AppUpdateRequest,
        candidate: AppUpdatePackage,
        installed: AppUpdatePackage,
        deviceSdk: Int,
    ) {
        if (candidate.packageName.isEmpty() || candidate.packageName != installed.packageName) {
            fail("update_package_mismatch")
        }
        if (candidate.versionName != request.versionName || candidate.versionCode != request.versionCode) {
            fail("update_version_mismatch")
        }
        if (candidate.versionCode <= installed.versionCode) fail("update_not_newer")
        if (candidate.minSdk < 1 || candidate.minSdk > deviceSdk) fail("update_incompatible")
        if (candidate.signerCertificates.isEmpty() || installed.signerCertificates.isEmpty() ||
            candidate.signerCertificates.any(String::isEmpty) ||
            installed.signerCertificates.any(String::isEmpty) ||
            candidate.signerCertificates != installed.signerCertificates
        ) {
            fail("update_signature_mismatch")
        }
    }

    private fun integer(value: Any?): Long? = when (value) {
        is Int -> value.toLong()
        is Long -> value
        else -> null
    }

    private fun fail(code: String): Nothing = throw AppUpdateException(code)
}
