package dev.ghostty.connect

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class OpenSourceNoticesTest {
    @Test
    fun packagedNoticesContainRuntimeComponentsAndLicenseTexts() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val notices = context.assets.open("open_source_notices.txt").bufferedReader().use { it.readText() }

        listOf("Ghostty", "Kotlin", "SSHJ", "ASN.1", "Bouncy Castle", "SLF4J").forEach {
            assertTrue("Missing notice for $it", notices.contains(it))
        }
        assertTrue(notices.contains("Permission is hereby granted, free of charge"))
        assertTrue(notices.contains("TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION"))
    }
}
