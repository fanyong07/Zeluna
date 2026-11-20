package app.anime.anime.update

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assume.assumeNoException
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AppUpdatePolicyTest {
    @get:Rule val temporaryFolder = TemporaryFolder()

    private val abcHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    private val installed = AppUpdatePackage("app.anime.anime", "1.0.0", 10, 24, setOf("cert-A"))
    private val candidate = installed.copy(versionName = "1.0.1", versionCode = 11)

    @Test
    fun channelIntegersAcceptIntAndLongWithoutLossyCoercion() {
        assertEquals(11L, AppUpdatePolicy.parseRequest(arguments()).versionCode)
        assertEquals(11L, AppUpdatePolicy.parseRequest(arguments() + ("versionCode" to 11L)).versionCode)
        assertEquals(3L, AppUpdatePolicy.parseRequest(arguments() + ("bytes" to 3L)).bytes)
        expect("update_version_mismatch") {
            AppUpdatePolicy.parseRequest(arguments() + ("versionCode" to 11.0))
        }
        expect("update_size_mismatch") { AppUpdatePolicy.parseRequest(arguments() + ("bytes" to "3")) }
    }

    @Test
    fun argumentsRequireLowercaseSha256AndPositiveBoundedSize() {
        for (hash in listOf(abcHash.uppercase(), "f".repeat(63), "g".repeat(64), " $abcHash")) {
            expect("update_hash_mismatch") { AppUpdatePolicy.parseRequest(arguments() + ("sha256" to hash)) }
        }
        for (bytes in listOf(0L, -1L, AppUpdatePolicy.MAX_APK_BYTES + 1)) {
            expect("update_size_mismatch") { AppUpdatePolicy.parseRequest(arguments() + ("bytes" to bytes)) }
        }
        assertEquals(
            AppUpdatePolicy.MAX_APK_BYTES,
            AppUpdatePolicy.parseRequest(arguments() + ("bytes" to AppUpdatePolicy.MAX_APK_BYTES)).bytes,
        )
    }

    @Test
    fun malformedArgumentsUseStableCodes() {
        expect("update_invalid_path") { AppUpdatePolicy.parseRequest(null) }
        expect("update_invalid_path") { AppUpdatePolicy.parseRequest(arguments() + ("path" to "\u0000")) }
        expect("update_hash_mismatch") { AppUpdatePolicy.parseRequest(arguments() - "sha256") }
        expect("update_version_mismatch") { AppUpdatePolicy.parseRequest(arguments() + ("versionName" to "")) }
        expect("update_version_mismatch") { AppUpdatePolicy.parseRequest(arguments() + ("versionCode" to 0)) }
    }

    @Test
    fun onlyCanonicalRegularApkInsidePrivateDirectoryIsAccepted() {
        val root = updateDirectory()
        val file = File(root, "update.apk").apply { writeText("abc") }
        assertEquals(file, AppUpdatePolicy.requireApkFile(root, file.path))
        val nested = File(root, "nested").apply { mkdir() }
        val nestedApk = File(nested, "nested.apk").apply { writeText("abc") }
        assertEquals(nestedApk, AppUpdatePolicy.requireApkFile(root, nestedApk.path))
        val directoryApk = File(root, "directory.apk").apply { mkdir() }
        val textFile = File(root, "update.txt").apply { writeText("abc") }
        for (path in listOf(root.path, directoryApk.path, textFile.path, "update.apk", File(root, "missing.apk").path)) {
            expect("update_invalid_path") { AppUpdatePolicy.requireApkFile(root, path) }
        }
    }

    @Test
    fun siblingPrefixAndTraversalEvenBackIntoRootAreRejected() {
        val root = updateDirectory()
        val file = File(root, "update.apk").apply { writeText("abc") }
        val sibling = File(root.parentFile, "app_updates_evil").apply { mkdir() }
        val outside = File(sibling, "outside.apk").apply { writeText("abc") }
        for (path in listOf(
            outside.path,
            root.path + File.separator + ".." + File.separator + "app_updates" + File.separator + file.name,
            root.path + File.separator + "." + File.separator + file.name,
        )) {
            expect("update_invalid_path") { AppUpdatePolicy.requireApkFile(root, path) }
        }
    }

    @Test
    fun symlinkToApkInsideSameDirectoryIsRejected() {
        val root = updateDirectory()
        val actual = File(root, "actual.apk").apply { writeText("abc") }
        val link = File(root, "link.apk")
        createSymlinkOrSkip(link, actual)
        expect("update_invalid_path") { AppUpdatePolicy.requireApkFile(root, link.path) }
    }

    @Test
    fun symlinkToOutsideDirectoryIsRejected() {
        val root = updateDirectory()
        val outside = temporaryFolder.newFolder("outside").canonicalFile
        File(outside, "outside.apk").writeText("abc")
        val link = File(root, "linked")
        createSymlinkOrSkip(link, outside)
        expect("update_invalid_path") {
            AppUpdatePolicy.requireApkFile(root, File(link, "outside.apk").path)
        }
    }

    @Test
    fun symlinkedTrustedDirectoryIsRejected() {
        val actual = temporaryFolder.newFolder("actual").canonicalFile
        File(actual, "update.apk").writeText("abc")
        val link = File(temporaryFolder.root.canonicalFile, "app_updates")
        createSymlinkOrSkip(link, actual)
        expect("update_invalid_path") { AppUpdatePolicy.requireApkFile(link, File(link, "update.apk").path) }
    }

    @Test
    fun hashAndExactSizeAreValidated() {
        val file = File(updateDirectory(), "update.apk").apply { writeText("abc") }
        AppUpdatePolicy.verifyFile(file, request(file.path))
        expect("update_hash_mismatch") {
            AppUpdatePolicy.verifyFile(file, request(file.path).copy(sha256 = "0".repeat(64)))
        }
        expect("update_size_mismatch") { AppUpdatePolicy.verifyFile(file, request(file.path).copy(bytes = 2)) }
        expect("update_size_mismatch") { AppUpdatePolicy.verifyFile(file, request(file.path).copy(bytes = 4)) }
    }

    @Test
    fun sameLengthTamperingIsDetectedOnEveryVerification() {
        val file = File(updateDirectory(), "update.apk").apply { writeText("abc") }
        val request = request(file.path)
        AppUpdatePolicy.verifyFile(file, request)
        file.writeText("abd")
        expect("update_hash_mismatch") { AppUpdatePolicy.verifyFile(file, request) }
    }

    @Test
    fun streamedGrowthAndCancellationAreDetected() {
        val file = File(updateDirectory(), "update.apk").apply { writeText("abc") }
        var changed = false
        expect("update_size_mismatch") {
            AppUpdatePolicy.verifyFile(file, request(file.path)) {
                if (!changed) {
                    changed = true
                    file.appendText("d")
                }
            }
        }
        file.writeText("abc")
        expect("update_closed") {
            AppUpdatePolicy.verifyFile(file, request(file.path)) { throw AppUpdateException("update_closed") }
        }
    }

    @Test
    fun exactPackageAndVersionMatchAreRequired() {
        val request = request()
        AppUpdatePolicy.verifyPackage(request, candidate, installed, 24)
        expect("update_package_mismatch") {
            AppUpdatePolicy.verifyPackage(request, candidate.copy(packageName = "another.app"), installed, 24)
        }
        expect("update_version_mismatch") {
            AppUpdatePolicy.verifyPackage(request, candidate.copy(versionName = "v1.0.1"), installed, 24)
        }
        expect("update_version_mismatch") {
            AppUpdatePolicy.verifyPackage(request, candidate.copy(versionCode = 12), installed, 24)
        }
    }

    @Test
    fun sameOrOlderBuildIsRejectedEvenWhenExpectedVersionMatches() {
        for (version in listOf(9L, 10L)) {
            expect("update_not_newer") {
                AppUpdatePolicy.verifyPackage(request().copy(versionCode = version), candidate.copy(versionCode = version), installed, 24)
            }
        }
    }

    @Test
    fun longVersionCodesRemainExact() {
        val next = Int.MAX_VALUE.toLong() + 100
        AppUpdatePolicy.verifyPackage(request().copy(versionCode = next), candidate.copy(versionCode = next), installed, 36)
        expect("update_version_mismatch") {
            AppUpdatePolicy.verifyPackage(request().copy(versionCode = next - 1), candidate.copy(versionCode = next), installed, 36)
        }
    }

    @Test
    fun minimumSdkMustBeSupported() {
        for (minSdk in listOf(0, -1, 25)) {
            expect("update_incompatible") {
                AppUpdatePolicy.verifyPackage(request(), candidate.copy(minSdk = minSdk), installed, 24)
            }
        }
        AppUpdatePolicy.verifyPackage(request(), candidate.copy(minSdk = 24), installed, 24)
    }

    @Test
    fun emptyOrDifferentCurrentSignerSetsAreRejected() {
        for (signers in listOf(emptySet(), setOf(""), setOf("cert-B"), setOf("cert-A", "cert-B"))) {
            expect("update_signature_mismatch") {
                AppUpdatePolicy.verifyPackage(request(), candidate.copy(signerCertificates = signers), installed, 24)
            }
        }
        expect("update_signature_mismatch") {
            AppUpdatePolicy.verifyPackage(request(), candidate, installed.copy(signerCertificates = emptySet()), 24)
        }
    }

    @Test
    fun multiSignerSetsMustMatchExactlyRegardlessOfOrder() {
        val multipleInstalled = installed.copy(signerCertificates = linkedSetOf("cert-A", "cert-B"))
        AppUpdatePolicy.verifyPackage(
            request(), candidate.copy(signerCertificates = linkedSetOf("cert-B", "cert-A")), multipleInstalled, 24,
        )
        expect("update_signature_mismatch") {
            AppUpdatePolicy.verifyPackage(request(), candidate, multipleInstalled, 24)
        }
        // A new current signer with the old certificate in its history is not an exact match.
        expect("update_signature_mismatch") {
            AppUpdatePolicy.verifyPackage(request(), candidate.copy(signerCertificates = setOf("cert-B")), installed, 24)
        }
    }

    @Test
    fun archiveMustContainManifestAndSupportedNativeAbi() {
        val supported = setOf("arm64-v8a", "armeabi-v7a")
        AppUpdatePolicy.verifyArchive(archive("AndroidManifest.xml", "classes.dex"), supported)
        AppUpdatePolicy.verifyArchive(archive("AndroidManifest.xml", "lib/arm64-v8a/libapp.so"), supported)
        AppUpdatePolicy.verifyArchive(archive("AndroidManifest.xml", "lib/x86_64/libapp.so", "lib/arm64-v8a/libapp.so"), supported)
        expect("update_incompatible") {
            AppUpdatePolicy.verifyArchive(archive("classes.dex"), supported)
        }
        expect("update_incompatible") {
            AppUpdatePolicy.verifyArchive(archive("AndroidManifest.xml", "lib/x86_64/libapp.so"), supported)
        }
    }

    @Test
    fun malformedArchiveAndCancelledInspectionFailClosed() {
        val corrupt = temporaryFolder.newFile("corrupt.apk").apply { writeText("not a zip") }
        expect("update_incompatible") { AppUpdatePolicy.verifyArchive(corrupt, setOf("arm64-v8a")) }
        val apk = archive("AndroidManifest.xml")
        expect("update_closed") {
            AppUpdatePolicy.verifyArchive(apk, setOf("arm64-v8a")) { throw AppUpdateException("update_closed") }
        }
    }

    @Test
    fun errorMessagesDoNotContainCallerPathsOrHashes() {
        val secretPath = File(temporaryFolder.root, "private-secret.apk").path
        val error = expect("update_invalid_path") {
            AppUpdatePolicy.requireApkFile(updateDirectory(), secretPath)
        }
        assertFalse(error.message.orEmpty().contains(secretPath))
        assertFalse(error.message.orEmpty().contains(abcHash))
    }

    private fun updateDirectory(): File = temporaryFolder.newFolder("app_updates").canonicalFile

    private fun arguments(): Map<String, Any> = mapOf(
        "path" to "/cache/app_updates/update.apk",
        "sha256" to abcHash,
        "bytes" to 3,
        "versionName" to "1.0.1",
        "versionCode" to 11,
    )

    private fun request(path: String = "/cache/app_updates/update.apk") =
        AppUpdateRequest(path, abcHash, 3, "1.0.1", 11)

    private fun expect(code: String, action: () -> Unit): AppUpdateException {
        val error = assertThrows(AppUpdateException::class.java, action)
        assertEquals(code, error.code)
        return error
    }

    private fun createSymlinkOrSkip(link: File, target: File) {
        try {
            Files.createSymbolicLink(link.toPath(), target.toPath())
        } catch (error: IOException) {
            assumeNoException("Host does not permit symbolic links", error)
        } catch (error: UnsupportedOperationException) {
            assumeNoException("Host does not support symbolic links", error)
        }
    }

    private fun archive(vararg names: String): File {
        val file = temporaryFolder.newFile("archive-${System.nanoTime()}.apk")
        ZipOutputStream(file.outputStream()).use { output ->
            names.forEach { name ->
                output.putNextEntry(ZipEntry(name))
                output.write(byteArrayOf(1, 2, 3))
                output.closeEntry()
            }
        }
        return file
    }
}
