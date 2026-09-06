package dev.ghostty.connect.terminal.view

import dev.ghostty.connect.model.HoldSwipeDirection
import kotlin.math.abs
import kotlin.math.hypot

internal class HoldSwipeGesture(
    private val cancelSlop: Float,
    private val selectionDistance: Float,
) {
    var active = false
        private set
    var direction: HoldSwipeDirection? = null
        private set
    var originX = 0f
        private set
    var originY = 0f
        private set
    var pending = false
        private set

    fun start(x: Float, y: Float) {
        originX = x
        originY = y
        pending = true
        active = false
        direction = null
    }

    fun activate(): Boolean {
        if (!pending) return false
        pending = false
        active = true
        return true
    }

    fun move(x: Float, y: Float): HoldSwipeDirection? {
        val dx = x - originX
        val dy = y - originY
        if (pending && hypot(dx.toDouble(), dy.toDouble()) > cancelSlop) pending = false
        if (!active) return null
        direction = if (hypot(dx.toDouble(), dy.toDouble()) < selectionDistance) null else if (abs(dx) > abs(dy)) {
            if (dx > 0) HoldSwipeDirection.RIGHT else HoldSwipeDirection.LEFT
        } else {
            if (dy > 0) HoldSwipeDirection.DOWN else HoldSwipeDirection.UP
        }
        return direction
    }

    fun finish(): HoldSwipeDirection? {
        val result = direction
        cancel()
        return result
    }

    fun pin() {
        pending = false
        active = true
        direction = null
    }

    fun cancel() {
        pending = false
        active = false
        direction = null
    }
}
