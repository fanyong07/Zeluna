package app.anime.anime.update

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.Settings
import android.system.Os
import android.system.OsConstants
import android.util.Base64
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/** No network, package removal, silent installation, or caller-supplied Intent fields. */
class AppUpdateMethodChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : AutoCloseable {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "zeluna-app-update").apply { isDaemon = true }
    }
    private val lifecycleLock = Any()
    @Volatile private var closed = false
    // Accessed only on the main thread. Informational calls remain available while busy.
    private var pendingResult: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler(::onMethodCall)
    }

    override fun close() {
        synchronized(lifecycleLock) {
            if (closed) return
            closed = true
            channel.setMethodCallHandler(null)
            mainHandler.removeCallbacksAndMessages(null)
        }
        worker.shutdownNow()
        val pending = pendingResult
        pendingResult = null
        pending?.error("update_closed", "The update bridge is closed.", null)
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            requireActiveActivity()
            when (call.method) {
                "getEnvironment" -> result.success(environment())
                "getDownloadDirectory" -> {
                    val directory = downloadDirectory()
                    result.success(mapOf(
                        "path" to directory.path,
                        "availableBytes" to StatFs(directory.path).availableBytes,
                    ))
                }
                "openInstallPermission" -> result.success(openInstallPermission())
                "verifyPackage", "installPackage" -> {
                    if (pendingResult != null) throw AppUpdateException("update_busy")
                    val request = AppUpdatePolicy.parseRequest(call.arguments)
                    verifyAsync(request, call.method == "installPackage", result)
                }
                else -> result.notImplemented()
            }
        } catch (error: AppUpdateException) {
            result.error(error.code, error.message, null)
        } catch (_: Exception) {
            result.error("update_install_failed", "The Android update operation failed.", null)
        }
    }

    private fun verifyAsync(
        request: AppUpdateRequest,
        install: Boolean,
        result: MethodChannel.Result,
    ) {
        pendingResult = result
        try {
            worker.execute {
                try {
                    val verified = verify(request)
                    deliver(result) {
                        if (install) launchInstaller(verified) else mapOf("verified" to true)
                    }
                } catch (error: AppUpdateException) {
                    deliver(result) { throw error }
                } catch (_: Exception) {
                    deliver(result) { throw AppUpdateException("update_install_failed") }
                }
            }
        } catch (_: RejectedExecutionException) {
            pendingResult = null
            throw AppUpdateException(if (closed) "update_closed" else "update_install_failed")
        }
    }

    /** Lock posting against close() so a worker cannot enqueue a late Activity launch. */
    private fun deliver(result: MethodChannel.Result, response: () -> Any) {
        synchronized(lifecycleLock) {
            if (closed) return
            mainHandler.post {
                if (closed || pendingResult !== result) return@post
                try {
                    requireActiveActivity()
                    result.success(response())
                } catch (error: AppUpdateException) {
                    result.error(error.code, error.message, null)
                } catch (_: Exception) {
                    result.error("update_install_failed", "The Android update operation failed.", null)
                } finally {
                    pendingResult = null
                }
            }
        }
    }

    private fun requireWorkerActive() {
        if (closed || Thread.currentThread().isInterrupted) throw AppUpdateException("update_closed")
    }

    private fun requireActiveActivity() {
        if (closed || activity.isFinishing || activity.isDestroyed) throw AppUpdateException("update_closed")
    }

    private fun downloadDirectory(): File {
        // Canonicalize the trusted OS cache parent, never a caller-controlled path.
        val directory = File(activity.cacheDir.canonicalFile, "app_updates")
        if (directory.absoluteFile != directory.canonicalFile) throw AppUpdateException("update_invalid_path")
        if (!directory.exists() && !directory.mkdir() && !directory.isDirectory) {
            throw AppUpdateException("update_invalid_path")
        }
        if (!directory.isDirectory || directory.absoluteFile != directory.canonicalFile) {
            throw AppUpdateException("update_invalid_path")
        }
        return directory
    }

    private fun environment(): Map<String, Any> {
        val info = installedPackageInfo()
        return mapOf(
            "packageName" to activity.packageName,
            "versionName" to info.versionName.orEmpty(),
            "versionCode" to versionCode(info),
            "sdkInt" to Build.VERSION.SDK_INT,
            "supportedAbis" to Build.SUPPORTED_ABIS.toList(),
            "canRequestInstallPackages" to canRequestInstallPackages(),
        )
    }

    private fun canRequestInstallPackages(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || activity.packageManager.canRequestPackageInstalls()

    private fun openInstallPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        requireActiveActivity()
        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:${activity.packageName}"),
        )
        // Package visibility may hide a settings resolver; startActivity is the
        // definitive check. No pending install is retained or resumed afterwards.
        intent.resolveActivity(activity.packageManager)
        return try {
            activity.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun verify(request: AppUpdateRequest): VerifiedApk {
        requireWorkerActive()
        val directory = downloadDirectory()
        val file = AppUpdatePolicy.requireApkFile(directory, request.path)
        val stamp = fileStamp(file)
        AppUpdatePolicy.verifyFile(file, request, ::requireWorkerActive)
        AppUpdatePolicy.verifyArchive(file, Build.SUPPORTED_ABIS.toSet(), ::requireWorkerActive)
        requireWorkerActive()
        val candidateInfo = archivePackageInfo(file)
            ?: throw AppUpdateException("update_incompatible")
        val currentInfo = installedPackageInfo()
        val installed = packageMetadata(currentInfo)
        if (installed.packageName != activity.packageName) throw AppUpdateException("update_package_mismatch")
        AppUpdatePolicy.verifyPackage(
            request,
            packageMetadata(candidateInfo),
            installed,
            Build.VERSION.SDK_INT,
        )
        requireWorkerActive()
        requireUnchanged(VerifiedApk(directory, file, stamp))
        return VerifiedApk(directory, file, stamp)
    }

    @Suppress("DEPRECATION")
    private fun installedPackageInfo(): PackageInfo =
        activity.packageManager.getPackageInfo(activity.packageName, signatureFlags())

    @Suppress("DEPRECATION")
    private fun archivePackageInfo(file: File): PackageInfo? =
        activity.packageManager.getPackageArchiveInfo(file.path, signatureFlags())

    @Suppress("DEPRECATION")
    private fun signatureFlags(): Int = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        PackageManager.GET_SIGNING_CERTIFICATES
    } else {
        PackageManager.GET_SIGNATURES
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun packageMetadata(info: PackageInfo): AppUpdatePackage {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            // Only current signers; deliberately do not guess signing-key rotation.
            info.signingInfo?.apkContentsSigners
        } else {
            info.signatures
        }
        // This is a fail-closed signer identity precheck, not a replacement for
        // the system package installer's final cryptographic APK verification.
        val certificates = signatures.orEmpty().map { signature ->
            Base64.encodeToString(signature.toByteArray(), Base64.NO_WRAP)
        }.toSet()
        return AppUpdatePackage(
            packageName = info.packageName.orEmpty(),
            versionName = info.versionName.orEmpty(),
            versionCode = versionCode(info),
            minSdk = info.applicationInfo?.minSdkVersion ?: -1,
            signerCertificates = certificates,
        )
    }

    private fun fileStamp(file: File): FileStamp {
        try {
            val stat = Os.lstat(file.path)
            if (!OsConstants.S_ISREG(stat.st_mode)) throw AppUpdateException("update_invalid_path")
            return FileStamp(stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime, stat.st_ctime)
        } catch (error: AppUpdateException) {
            throw error
        } catch (_: Exception) {
            throw AppUpdateException("update_invalid_path")
        }
    }

    private fun requireUnchanged(verified: VerifiedApk) {
        AppUpdatePolicy.requireApkFile(verified.directory, verified.file.path)
        if (fileStamp(verified.file) != verified.stamp) throw AppUpdateException("update_hash_mismatch")
    }

    @Suppress("DEPRECATION")
    private fun launchInstaller(verified: VerifiedApk): Map<String, String> {
        requireActiveActivity()
        requireUnchanged(verified)
        if (!canRequestInstallPackages()) return mapOf("status" to "permissionRequired")
        val uri = FileProvider.getUriForFile(
            activity,
            "${activity.packageName}.app_updates",
            verified.file,
        )
        val intents = listOf(Intent.ACTION_INSTALL_PACKAGE, Intent.ACTION_VIEW).map { action ->
            Intent(action).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = ClipData.newRawUri("Application update", uri)
            }
        }
        // Prefer a visible installer. Android 11+ package visibility can make
        // resolveActivity return null even when startActivity is supported, so
        // also attempt the fixed APK-only intents and handle absence explicitly.
        val ordered = intents.sortedByDescending { it.resolveActivity(activity.packageManager) != null }
        for (intent in ordered) {
            requireActiveActivity()
            requireUnchanged(verified)
            try {
                activity.startActivity(intent)
                return mapOf("status" to "launched")
            } catch (_: android.content.ActivityNotFoundException) {
                // Try the other standard APK installer action.
            } catch (_: SecurityException) {
                if (!canRequestInstallPackages()) return mapOf("status" to "permissionRequired")
            }
        }
        throw AppUpdateException("update_install_failed")
    }

    private data class FileStamp(
        val device: Long,
        val inode: Long,
        val bytes: Long,
        val modifiedSeconds: Long,
        val changedSeconds: Long,
    )

    private data class VerifiedApk(val directory: File, val file: File, val stamp: FileStamp)

    companion object {
        const val CHANNEL_NAME = "app.anime.anime/app-update"
    }
}
