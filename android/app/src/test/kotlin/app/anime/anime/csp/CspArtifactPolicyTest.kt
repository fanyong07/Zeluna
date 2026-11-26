package app.anime.anime.csp

import java.io.File
import java.io.FileOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.Assert.assertThrows

class CspArtifactPolicyTest {
    @get:Rule
    val temporaryFolder = TemporaryFolder()

    @Test
    fun pinnedArtifactsUseImmutableHttpsUrlsAndBothDigests() {
        assertEquals(2, CspArtifactPolicy.pinnedArtifacts.size)
        for (spec in CspArtifactPolicy.pinnedArtifacts) {
            CspArtifactPolicy.requirePinnedArtifact(spec)
            assertEquals(spec, CspArtifactPolicy.requireKnownArtifact(spec.md5))
            assertTrue(spec.url.startsWith("https://raw.githubusercontent.com/"))
            assertFalse(spec.url.contains("/master/"))
            assertEquals(32, spec.md5.length)
            assertEquals(64, spec.sha256.length)
            assertTrue(spec.allowedApis.isNotEmpty())
        }
    }

    @Test
    fun importedArtifactMetadataCannotWidenAllowlist() {
        val pinned = CspArtifactPolicy.gaoArtifact
        val guard = pinned.copy(
            id = "qist-guard",
            url = "https://raw.githubusercontent.com/qist/tvbox/master/jar/fan.txt",
        )

        val error = assertThrows(CspBridgeException::class.java) {
            CspArtifactPolicy.requirePinnedArtifact(guard)
        }
        assertEquals("csp_artifact_not_allowed", error.code)
    }

    @Test
    fun guardAndDianshiDigestsAreRejected() {
        for (md5 in listOf(
            "8432d174d72d5b608ae1bcd16d966847",
            "e05436bdbed170e00d2537ffd032778e",
        )) {
            val error = assertThrows(CspBridgeException::class.java) {
                CspArtifactPolicy.requireKnownArtifact(md5)
            }
            assertEquals("csp_artifact_not_allowed", error.code)
        }
    }

    @Test
    fun eachPackageUsesItsOwnAuditedClassAllowlist() {
        val gaoMd5 = CspArtifactPolicy.gaoArtifact.md5
        val qistMd5 = CspArtifactPolicy.qistArtifact.md5
        assertEquals(
            "csp_DouDou",
            CspArtifactPolicy.requireAllowedApi(gaoMd5, " csp_DouDou "),
        )
        assertEquals(
            "csp_XPathMacFilter",
            CspArtifactPolicy.requireAllowedApi(qistMd5, "csp_XPathMacFilter"),
        )
        assertEquals("csp_Wogg", CspArtifactPolicy.requireAllowedApi(qistMd5, "csp_Wogg"))
        assertThrows(CspBridgeException::class.java) {
            CspArtifactPolicy.requireAllowedApi(gaoMd5, "csp_AppSKGuard")
        }
        assertThrows(CspBridgeException::class.java) {
            CspArtifactPolicy.requireAllowedApi(gaoMd5, "csp_XBPQ")
        }
        assertThrows(CspBridgeException::class.java) {
            CspArtifactPolicy.requireAllowedApi(gaoMd5, "csp_XPath")
        }
        for (missing in listOf("csp_Dovx", "csp_NiNi", "csp_Ying")) {
            assertThrows(CspBridgeException::class.java) {
                CspArtifactPolicy.requireAllowedApi(qistMd5, missing)
            }
        }
    }

    @Test
    fun digestComputationIsBoundedAndDeterministic() {
        val file = temporaryFolder.newFile("digest.bin").apply {
            writeBytes("abc".toByteArray())
        }

        val digests = CspArtifactPolicy.computeDigests(file, maxBytes = 3)
        assertEquals("900150983cd24fb0d6963f7d28e17f72", digests.md5)
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223" +
                "b00361a396177a9cb410ff61f20015ad",
            digests.sha256,
        )
        assertThrows(CspBridgeException::class.java) {
            CspArtifactPolicy.computeDigests(file, maxBytes = 2)
        }
    }

    @Test
    fun pureSingleDexArchivePassesStructureValidation() {
        val archive = createArchive(
            "classes.dex" to dexBytes(),
            "META-INF/MANIFEST.MF" to "Manifest-Version: 1.0\n".toByteArray(),
        )

        CspArtifactPolicy.validatePureDexArchive(archive)
    }

    @Test
    fun guardOrNativePayloadIsRejected() {
        val archive = createArchive(
            "classes.dex" to dexBytes(),
            "assets/ftyguard_v8.so" to byteArrayOf(0x7f, 'E'.code.toByte()),
        )

        val error = assertThrows(CspBridgeException::class.java) {
            CspArtifactPolicy.validatePureDexArchive(archive)
        }
        assertEquals("csp_native_code_rejected", error.code)
    }

    @Test
    fun multipleDexPayloadsAreRejected() {
        val archive = createArchive(
            "classes.dex" to dexBytes(),
            "classes2.dex" to dexBytes(),
        )

        assertThrows(CspBridgeException::class.java) {
            CspArtifactPolicy.validatePureDexArchive(archive)
        }
    }

    private fun createArchive(vararg entries: Pair<String, ByteArray>): File {
        val file = temporaryFolder.newFile("artifact-${System.nanoTime()}.zip")
        ZipOutputStream(FileOutputStream(file)).use { output ->
            entries.forEach { (name, bytes) ->
                output.putNextEntry(ZipEntry(name))
                output.write(bytes)
                output.closeEntry()
            }
        }
        return file
    }

    private fun dexBytes(): ByteArray =
        byteArrayOf(
            'd'.code.toByte(),
            'e'.code.toByte(),
            'x'.code.toByte(),
            '\n'.code.toByte(),
            '0'.code.toByte(),
            '3'.code.toByte(),
            '5'.code.toByte(),
            0,
            1,
            2,
            3,
        )
}
