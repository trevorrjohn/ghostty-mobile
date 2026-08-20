package dev.ghostty.connect.terminal

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

data class AuthenticationChallenge(
    val title: String,
    val instruction: String,
    val prompt: String,
    val echo: Boolean,
)

internal class ExactlyOnceAnswer<T>(private val deliver: (T?) -> Unit) {
    private val answered = AtomicBoolean(false)

    val isAnswered: Boolean get() = answered.get()

    fun answer(value: T?): Boolean {
        if (!answered.compareAndSet(false, true)) return false
        deliver(value)
        return true
    }
}

internal class ChallengeResponseAwaiter {
    private val latch = CountDownLatch(1)
    private val answer = ExactlyOnceAnswer<CharArray> {
        response = it
        latch.countDown()
    }
    @Volatile private var response: CharArray? = null

    fun answer(value: CharArray?): Boolean = answer.answer(value)

    fun await(timeout: Long, unit: TimeUnit): CharArray? {
        if (latch.await(timeout, unit)) return response
        return if (answer.answer(null)) null else response
    }
}
