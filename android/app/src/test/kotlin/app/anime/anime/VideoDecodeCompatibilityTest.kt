package app.anime.anime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoDecodeCompatibilityTest {
    @Test fun x86RuntimeBypassesTheStalledHardwareDecoder() {
        assertTrue(VideoDecodeCompatibility.requiresSoftwareDecode("x86_64"))
        assertTrue(VideoDecodeCompatibility.requiresSoftwareDecode("x86"))
    }

    @Test fun armPhonesAndUnknownRuntimesKeepAutomaticDecoding() {
        assertFalse(VideoDecodeCompatibility.requiresSoftwareDecode("arm64-v8a"))
        assertFalse(VideoDecodeCompatibility.requiresSoftwareDecode("armeabi-v7a"))
        assertFalse(VideoDecodeCompatibility.requiresSoftwareDecode(null))
        assertFalse(VideoDecodeCompatibility.requiresSoftwareDecode(""))
    }
}
