package app.anime.anime

import org.junit.Assert.assertEquals
import org.junit.Test

class PlayerPipAspectRatioTest {
    @Test fun keepsValidRatioAndDefaultsIncompleteInput() {
        assertEquals(9 to 16, pipAspectRatio(9, 16))
        assertEquals(16 to 9, pipAspectRatio(null, 900))
        assertEquals(16 to 9, pipAspectRatio(100, 0))
    }

    @Test fun clampsBothExtremesWithoutOverflow() {
        assertEquals(42 to 100, pipAspectRatio(1, Int.MAX_VALUE))
        assertEquals(239 to 100, pipAspectRatio(Int.MAX_VALUE, 1))
    }
}
