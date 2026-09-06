package dev.ghostty.connect.terminal.view

import dev.ghostty.connect.model.HoldSwipeDirection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HoldSwipeGestureTest {
    @Test fun movementBeforeActivationCancels() {
        val gesture = HoldSwipeGesture(8f, 40f)
        gesture.start(100f, 100f)
        gesture.move(109f, 100f)
        assertFalse(gesture.activate())
    }

    @Test fun releaseInsideDeadZoneCancels() {
        val gesture = HoldSwipeGesture(8f, 40f)
        gesture.start(100f, 100f)
        assertTrue(gesture.activate())
        gesture.move(120f, 100f)
        assertNull(gesture.finish())
    }

    @Test fun activeGestureTracksDominantDirection() {
        val gesture = HoldSwipeGesture(8f, 40f)
        gesture.start(100f, 100f)
        gesture.activate()
        assertEquals(HoldSwipeDirection.RIGHT, gesture.move(150f, 110f))
        assertEquals(HoldSwipeDirection.UP, gesture.move(90f, 40f))
        assertEquals(HoldSwipeDirection.UP, gesture.finish())
        assertFalse(gesture.active)
    }

    @Test fun pinKeepsMenuActiveButClearsSwipeSelection() {
        val gesture = HoldSwipeGesture(8f, 40f)
        gesture.start(100f, 100f)
        gesture.activate()
        gesture.move(150f, 100f)

        gesture.pin()

        assertTrue(gesture.active)
        assertNull(gesture.direction)
    }
}
