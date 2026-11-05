package app.anime.anime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeVideoSurfaceTest {
    @Test fun onlyAffectedEmulatorUsesDirectSurface() {
        assertTrue(VideoDecodeCompatibility.requiresDirectSurface(
            35, "x86_64", "ranchu", "google/sdk_gphone64_x86_64/emulator:15", "sdk_gphone64_x86_64", "sdk gphone"))
        assertFalse(VideoDecodeCompatibility.requiresDirectSurface(
            34, "x86_64", "ranchu", "generic/test", "sdk", "Android SDK built for x86"))
        assertFalse(VideoDecodeCompatibility.requiresDirectSurface(
            35, "arm64-v8a", "ranchu", "generic/test", "sdk", "Android SDK built for arm64"))
        assertFalse(VideoDecodeCompatibility.requiresDirectSurface(
            35, "x86_64", "intel", "vendor/device/device:15", "real_device", "Phone"))
        assertFalse(VideoDecodeCompatibility.requiresDirectSurface(
            35, "x86_64", null, null, null, null))
    }

    @Test fun aSurfaceSizeDoesNotCountAsAnImage() {
        val frame = NativeSurfaceFrameLedger(7, 3)
        assertEquals(0L, frame.frames)
        assertEquals(0, frame.width)
        assertFalse(frame.consumed(1L, 0, 720))
        assertFalse(frame.consumed(0L, 1280, 720))
        assertFalse(frame.consumed(1L, 1, 1))
        assertEquals(0L, frame.frames)
        assertTrue(frame.consumed(100L, 1280, 720))
        assertEquals(1L, frame.frames)
        assertEquals(1280, frame.width)
        assertEquals(720, frame.height)
        frame.close()
        assertFalse(frame.consumed(200L, 1920, 1080))
        assertEquals(1L, frame.frames)
    }

    @Test fun redrawOfTheSameBufferDoesNotInflateFrameCount() {
        val frame = NativeSurfaceFrameLedger(1, 1)
        assertTrue(frame.consumed(100L, 640, 360))
        assertFalse(frame.consumed(100L, 640, 360))
        assertFalse(frame.consumed(99L, 640, 360))
        assertTrue(frame.consumed(200L, 640, 360))
        assertEquals(2L, frame.frames)
    }

    @Test fun resizingMetadataDoesNotCreateAFrameOrResetItsEpoch() {
        val dimensions = NativeSurfaceDimensions(7, 3, 1, 1)
        val frame = NativeSurfaceFrameLedger(7, 3)
        assertTrue(dimensions.resize(7, 3, 1920, 1080))
        assertEquals(NativeSurfaceSize(1920, 1080), dimensions.current)
        assertEquals(0L, frame.frames)
        assertEquals(0, frame.width)
        assertEquals(0, frame.height)
        val size = dimensions.current
        assertTrue(frame.consumed(100L, size.width, size.height))
        assertEquals(1L, frame.frames)
        assertEquals(1920, frame.width)
        assertEquals(1080, frame.height)
        assertTrue(dimensions.resize(7, 3, 1280, 720))
        // A dimension event cannot rewrite the last real consumed-buffer record.
        assertEquals(1L, frame.frames)
        assertEquals(1920, frame.width)
        assertEquals(7, frame.openSerial)
        assertEquals(3, frame.epoch)
        val resized = dimensions.current
        assertTrue(frame.consumed(200L, resized.width, resized.height))
        assertEquals(2L, frame.frames)
        assertEquals(1280, frame.width)
        assertEquals(720, frame.height)
    }

    @Test fun staleInvalidOrClosedMetadataResizeCannotMutateTheActiveOutput() {
        val dimensions = NativeSurfaceDimensions(8, 5, 640, 360)
        assertFalse(dimensions.resize(7, 5, 1920, 1080))
        assertFalse(dimensions.resize(8, 4, 1920, 1080))
        assertFalse(dimensions.resize(8, 5, 0, 1080))
        assertFalse(dimensions.resize(8, 5, 8193, 1080))
        assertFalse(dimensions.resize(8, 5, 8192, 8192))
        assertEquals(NativeSurfaceSize(640, 360), dimensions.current)
        dimensions.close()
        assertFalse(dimensions.resize(8, 5, 1920, 1080))
        assertEquals(NativeSurfaceSize(640, 360), dimensions.current)
    }

    @Test fun newOpenAndNewSurfaceHaveIndependentCounts() {
        val old = NativeSurfaceFrameLedger(1, 4)
        old.consumed(100L, 1280, 720)
        old.close()
        val next = NativeSurfaceFrameLedger(2, 5)
        assertEquals(0L, next.frames)
        assertEquals(2, next.openSerial)
        assertEquals(5, next.epoch)
        old.consumed(100L, 1280, 720)
        assertEquals(0L, next.frames)
    }
}
