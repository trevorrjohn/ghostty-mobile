package dev.ghostty.connect.data

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DiagnosticStoreTest {
    private lateinit var context: Context

    @Before
    fun setUp() {
        context = InstrumentationRegistry.getInstrumentation().targetContext
        context.deleteFile(FILE_NAME)
    }

    @After
    fun tearDown() {
        context.deleteFile(FILE_NAME)
    }

    @Test
    fun diagnosticsAreBoundedAndPersistAcrossInstances() {
        val store = DiagnosticStore(context)
        repeat(55) { store.record(DiagnosticStage.BIOMETRIC_PROMPT_ERROR, resultCode = it) }

        val restored = DiagnosticStore(context).loadAll()

        assertEquals(50, restored.size)
        assertEquals(5, restored.first().resultCode)
        assertEquals(54, restored.last().resultCode)
    }

    @Test
    fun exportIncludesExceptionTypesButNeverMessages() {
        val secretMessage = "identity-id-and-path-must-not-export"
        DiagnosticStore(context).record(
            DiagnosticStage.BIOMETRIC_PROTECTION_COMMIT_FAILED,
            error = IllegalStateException(secretMessage, SecurityException("nested-secret")),
        )

        val export = DiagnosticStore(context).formatForExport()

        assertTrue(export.contains("IllegalStateException -> SecurityException"))
        assertFalse(export.contains(secretMessage))
        assertFalse(export.contains("nested-secret"))
    }

    companion object {
        private const val FILE_NAME = "diagnostics.enc"
    }
}
