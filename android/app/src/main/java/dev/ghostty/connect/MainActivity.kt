package dev.ghostty.connect

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import dev.ghostty.connect.data.HostStore
import dev.ghostty.connect.data.SshKeyStore
import dev.ghostty.connect.model.Host
import dev.ghostty.connect.terminal.SshConnection
import dev.ghostty.connect.terminal.bridge.GhosttyTerminal
import dev.ghostty.connect.terminal.view.GhosttyTerminalView

class MainActivity : Activity() {
    private lateinit var hostStore: HostStore
    private lateinit var keyStore: SshKeyStore
    private var connection: SshConnection? = null
    private var previewTerminal: GhosttyTerminal? = null
    private var liveTerminal: GhosttyTerminal? = null
    private val surface = Color.rgb(17, 19, 24)
    private val raised = Color.rgb(26, 29, 36)
    private val primary = Color.rgb(241, 243, 248)
    private val secondary = Color.rgb(174, 182, 198)
    private val accent = Color.rgb(139, 233, 179)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.decorView.setOnApplyWindowInsetsListener { view, insets ->
            val bars = if (android.os.Build.VERSION.SDK_INT >= 30) {
                insets.getInsets(WindowInsets.Type.systemBars())
            } else {
                @Suppress("DEPRECATION")
                android.graphics.Insets.of(
                    insets.systemWindowInsetLeft,
                    insets.systemWindowInsetTop,
                    insets.systemWindowInsetRight,
                    insets.systemWindowInsetBottom,
                )
            }
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
        hostStore = HostStore(this)
        keyStore = SshKeyStore(this)
        showHosts()
    }

    private fun showHosts() {
        connection?.disconnect()
        connection = null
        previewTerminal?.close()
        previewTerminal = null
        liveTerminal?.close()
        liveTerminal = null
        val root = vertical(24)
        root.addView(label("Ghostty Connect", 28f, primary, Typeface.BOLD))
        root.addView(label("A fast, native SSH terminal", 15f, secondary).margins(bottom = 28))
        hostStore.load()?.let { host ->
            val card = vertical(18).apply { setBackgroundColor(raised) }
            card.addView(label(host.name, 20f, primary, Typeface.BOLD))
            card.addView(label(host.destination, 14f, secondary))
            card.addView(label(host.keyName?.let { "Key · $it" } ?: "Password", 14f, accent).margins(top = 8))
            card.setOnClickListener { requestCredentialAndConnect(host) }
            root.addView(card.margins(bottom = 16))
        }
        root.addView(button(if (hostStore.load() == null) "Add your first host" else "Add or edit host") { showHostEditor() })
        root.addView(button("Import SSH key", secondary) { openKeyPicker() }.margins(top = 10))
        root.addView(button("Paste private key", secondary) { showPasteKeyDialog() }.margins(top = 10))
        root.addView(button("Ghostty renderer preview", secondary) { showGhosttyPreview() }.margins(top = 10))
        if (keyStore.names().isNotEmpty()) {
            root.addView(label("Imported keys: ${keyStore.names().joinToString()}", 13f, secondary).margins(top = 14))
        }
        setContentView(scroll(root))
    }

    private fun showHostEditor() {
        val existing = hostStore.load()
        val root = vertical(24)
        root.addView(label("Connection", 28f, primary, Typeface.BOLD))
        val name = field("Name", existing?.name.orEmpty())
        val hostname = field("Hostname or IP", existing?.hostname.orEmpty())
        val username = field("Username", existing?.username.orEmpty())
        val port = field("Port", existing?.port?.toString() ?: "22", InputType.TYPE_CLASS_NUMBER)
        listOf(name, hostname, username, port).forEach { root.addView(it.margins(bottom = 12)) }

        root.addView(label("Authentication", 14f, secondary).margins(top = 6, bottom = 6))
        val choices = listOf("Password") + keyStore.names().map { "SSH key · $it" }
        val authentication = Spinner(this).apply {
            adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_dropdown_item, choices)
            setBackgroundColor(raised)
            val selected = existing?.keyName?.let { choices.indexOf("SSH key · $it") } ?: 0
            setSelection(selected.coerceAtLeast(0))
        }
        root.addView(authentication.margins(bottom = 16))
        root.addView(button("Save host") {
            val parsedPort = port.text.toString().toIntOrNull()
            if (hostname.text.isBlank() || username.text.isBlank() || parsedPort !in 1..65535) {
                toast("Enter a hostname, username, and valid port.")
                return@button
            }
            val selected = authentication.selectedItem.toString()
            hostStore.save(Host(
                name = name.text.toString().ifBlank { hostname.text.toString() },
                hostname = hostname.text.toString().trim(),
                port = parsedPort!!,
                username = username.text.toString().trim(),
                keyName = selected.takeIf { it.startsWith("SSH key · ") }?.removePrefix("SSH key · "),
            ))
            showHosts()
        })
        root.addView(button("Import another key", secondary) { openKeyPicker() }.margins(top = 8))
        root.addView(button("Paste a private key", secondary) { showPasteKeyDialog() }.margins(top = 8))
        root.addView(button("Cancel", secondary) { showHosts() }.margins(top = 8))
        setContentView(scroll(root))
    }

    private fun openKeyPicker() {
        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }, IMPORT_KEY)
    }

    private fun showPasteKeyDialog() {
        val form = vertical(16)
        val name = field("Key name", "")
        val privateKey = EditText(this).apply {
            hint = "-----BEGIN OPENSSH PRIVATE KEY-----"
            setHintTextColor(secondary)
            setTextColor(primary)
            typeface = Typeface.MONOSPACE
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            minLines = 8
            gravity = Gravity.TOP
            setBackgroundColor(raised)
            setPadding(dp(12), dp(12), dp(12), dp(12))
        }
        form.addView(name.margins(bottom = 10))
        form.addView(privateKey, LinearLayout.LayoutParams(-1, dp(260)))
        val dialog = AlertDialog.Builder(this)
            .setTitle("Paste private key")
            .setView(form)
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Save", null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                try {
                    val value = privateKey.text.toString().trim()
                    require(value.contains("PRIVATE KEY")) { "Paste a PEM or OpenSSH private key" }
                    keyStore.import(name.text.toString().ifBlank { "Pasted key" }, (value + "\n").toByteArray())
                    privateKey.text.clear()
                    dialog.dismiss()
                    toast("Private key saved")
                    showHostEditor()
                } catch (error: Exception) {
                    toast(error.message ?: "Could not save key")
                }
            }
        }
        dialog.show()
    }

    @Deprecated("Activity result callback retained without an AndroidX dependency")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != IMPORT_KEY || resultCode != RESULT_OK) return
        val uri = data?.data ?: return
        try {
            val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: error("Could not read key")
            val text = bytes.toString(Charsets.UTF_8)
            require(text.contains("PRIVATE KEY")) { "Select a private SSH key file" }
            val displayName = uri.lastPathSegment?.substringAfterLast('/')?.takeLast(80) ?: "SSH key"
            keyStore.import(displayName, bytes)
            toast("Imported $displayName")
            showHostEditor()
        } catch (error: Exception) {
            toast(error.message ?: "Could not import key")
        }
    }

    private fun requestCredentialAndConnect(host: Host) {
        val credential = field(
            if (host.keyName == null) "Password" else "Key passphrase (blank if none)",
            "",
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD,
        )
        AlertDialog.Builder(this)
            .setTitle(if (host.keyName == null) "Authenticate" else "Unlock ${host.keyName}")
            .setView(credential)
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Connect") { _, _ -> showTerminal(host, credential.text.toString()) }
            .show()
    }

    private fun showGhosttyPreview() {
        val terminal = GhosttyTerminal().also { previewTerminal = it }
        terminal.write(
            "\u001b[2J\u001b[H" +
                "\u001b[1;38;2;139;233;179mGhostty Connect\u001b[0m\r\n" +
                "\u001b[38;2;174;182;198mNative libghostty-vt rendering spike\u001b[0m\r\n\r\n" +
                "\u001b[1;34m✓\u001b[0m ANSI colors and bold text\r\n" +
                "\u001b[3;35m✓ italic text\u001b[0m  \u001b[4;33munderlined text\u001b[0m\r\n" +
                "\u001b[48;2;40;44;52m 24-bit background color \u001b[0m\r\n" +
                "✓ Unicode: λ → 東京 👻\r\n" +
                "\u001b]0;this OSC title must stay invisible\u0007" +
                "\r\nThe cursor below is maintained by Ghostty.\r\n\r\n" +
                "~ ❯ ",
        )
        val root = vertical(0)
        val toolbar = vertical(16).apply { setBackgroundColor(raised) }
        toolbar.addView(label("Ghostty renderer", 18f, primary, Typeface.BOLD))
        toolbar.addView(label("Recorded native terminal fixture", 13f, accent))
        root.addView(toolbar)
        root.addView(GhosttyTerminalView(this, terminal), LinearLayout.LayoutParams(-1, 0, 1f))
        root.addView(button("Back to hosts", secondary) { showHosts() })
        setContentView(root)
    }

    private fun showTerminal(host: Host, credential: String) {
        val root = vertical(0)
        val status = label("Connecting…", 13f, accent)
        val toolbar = vertical(16).apply { setBackgroundColor(raised) }
        toolbar.addView(label(host.name, 18f, primary, Typeface.BOLD))
        toolbar.addView(status)
        root.addView(toolbar)

        val terminal = GhosttyTerminal().also { liveTerminal = it }
        val terminalView = GhosttyTerminalView(this, terminal).apply {
            isEnabled = false
            onInput = { connection?.send(it) }
            onResize = { columns, rows, pixelWidth, pixelHeight ->
                connection?.resize(columns, rows, pixelWidth, pixelHeight)
            }
        }
        root.addView(terminalView, LinearLayout.LayoutParams(-1, 0, 1f))
        val keys = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setBackgroundColor(raised) }
        val keyButtons = mutableListOf<Button>()
        listOf("Esc" to "\u001b", "Ctrl-C" to "\u0003", "Tab" to "\t", "↑" to "\u001b[A", "↓" to "\u001b[B").forEach { (name, bytes) ->
            val keyButton = button(name, secondary) { connection?.send(bytes) }.apply { isEnabled = false }
            keyButtons += keyButton
            keys.addView(keyButton, LinearLayout.LayoutParams(0, dp(44), 1f))
        }
        root.addView(keys)
        root.addView(button("Disconnect", secondary) { showHosts() })
        setContentView(root)

        connection = SshConnection(this, keyStore, object : SshConnection.Callbacks {
            override fun status(message: String) = runOnUiThread {
                status.text = "$message · ${host.destination}"
                val connected = message == "Connected"
                keyButtons.forEach { it.isEnabled = connected }
                terminalView.isEnabled = connected
                if (connected) terminalView.requestFocus()
            }
            override fun output(bytes: ByteArray) {
                terminal.write(bytes)
                runOnUiThread { terminalView.refresh() }
            }
            override fun verifyHostKey(fingerprint: String, changed: Boolean, answer: (Boolean) -> Unit) {
                runOnUiThread {
                    AlertDialog.Builder(this@MainActivity)
                        .setTitle(if (changed) "Host key changed" else "Unknown host")
                        .setMessage((if (changed) "The saved host key does not match. This could indicate an attack.\n\n" else "Verify this fingerprint with the server administrator:\n\n") + fingerprint)
                        .setNegativeButton("Reject") { _, _ -> answer(false) }
                        .setPositiveButton(if (changed) "Accept new key" else "Trust host") { _, _ -> answer(true) }
                        .setOnCancelListener { answer(false) }
                        .show()
                }
            }
            override fun closed(error: String?) = runOnUiThread {
                status.text = if (error == null) "Disconnected" else "Connection failed"
                terminalView.isEnabled = false
                keyButtons.forEach { it.isEnabled = false }
                error?.let {
                    terminal.write("\r\n\r\n\u001b[31mConnection failed:\u001b[0m $it\r\n")
                    terminalView.refresh()
                }
            }
        }).also { it.connect(host, credential) }
    }

    @Deprecated("Android framework callback; retained for API 29 compatibility")
    override fun onBackPressed() = showHosts()

    override fun onDestroy() {
        connection?.disconnect()
        previewTerminal?.close()
        liveTerminal?.close()
        super.onDestroy()
    }

    private fun vertical(padding: Int) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(padding), dp(padding), dp(padding), dp(padding))
        setBackgroundColor(surface)
    }
    private fun scroll(child: View) = ScrollView(this).apply { setBackgroundColor(surface); addView(child, ViewGroup.LayoutParams(-1, -2)) }
    private fun label(text: String, size: Float, color: Int, style: Int = Typeface.NORMAL) = TextView(this).apply {
        this.text = text; textSize = size; setTextColor(color); setTypeface(typeface, style)
    }
    private fun field(hint: String, value: String, type: Int = InputType.TYPE_CLASS_TEXT) = EditText(this).apply {
        this.hint = hint; setHintTextColor(secondary); setTextColor(primary); setText(value); inputType = type
        setSingleLine(true); setBackgroundColor(raised); setPadding(dp(14), dp(12), dp(14), dp(12))
    }
    private fun button(text: String, color: Int = accent, action: () -> Unit) = Button(this).apply {
        this.text = text; setTextColor(Color.rgb(8, 15, 12)); setBackgroundColor(color); isAllCaps = false; setOnClickListener { action() }
    }
    private fun View.margins(top: Int = 0, bottom: Int = 0): View = apply {
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(top); bottomMargin = dp(bottom) }
    }
    private fun toast(message: String) = Toast.makeText(this, message, Toast.LENGTH_LONG).show()
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    companion object { const val IMPORT_KEY = 1001 }
}
