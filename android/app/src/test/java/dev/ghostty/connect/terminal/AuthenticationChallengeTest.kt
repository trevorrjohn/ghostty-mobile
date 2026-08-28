package dev.ghostty.connect.terminal

import java.util.concurrent.TimeUnit
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AuthenticationChallengeTest {
    @Test
    fun exactlyOnceAnswerRejectsLaterResponses() {
        var delivered: String? = null
        val answer = ExactlyOnceAnswer<String> { delivered = it }

        assertTrue(answer.answer("first"))
        assertFalse(answer.answer("second"))
        assertTrue(answer.isAnswered)
        assertTrue(delivered == "first")
    }

    @Test
    fun nullableCancellationUnblocksAwaiter() {
        val response = ChallengeResponseAwaiter()

        assertTrue(response.answer(null))
        assertNull(response.await(1, TimeUnit.MILLISECONDS))
        assertFalse(response.answer("late".toCharArray()))
    }

    @Test
    fun responsePreservesCharactersForSshWorker() {
        val response = ChallengeResponseAwaiter()
        response.answer("123456".toCharArray())

        assertArrayEquals("123456".toCharArray(), response.await(1, TimeUnit.MILLISECONDS))
    }

    @Test
    fun canceledHostVerificationRejectsLateApproval() {
        var accepted: Boolean? = null
        val answer = ExactlyOnceAnswer<Boolean> { accepted = it }

        assertTrue(answer.answer(false))
        assertFalse(answer.answer(true))
        assertFalse(accepted!!)
    }

    @Test
    fun rejectedLateSecretIsWipedByPromptOwner() {
        val answer = ExactlyOnceAnswer<CharArray> {}
        val late = "late".toCharArray()
        assertTrue(answer.answer(null))

        if (!answer.answer(late)) late.fill('\u0000')

        assertTrue(late.all { it == '\u0000' })
    }
}
