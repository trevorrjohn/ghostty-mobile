package dev.ghostty.connect

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.annotation.SuppressLint
import android.content.Intent
import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.IBinder
import android.os.Build
import android.content.pm.PackageManager
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.window.OnBackInvokedDispatcher
import android.widget.ArrayAdapter
import android.widget.AdapterView
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import dev.ghostty.connect.data.HostStore
import dev.ghostty.connect.data.SshKeyStore
import dev.ghostty.connect.model.AuthenticationType
import dev.ghostty.connect.model.Host
import dev.ghostty.connect.terminal.SshSessionService
import dev.ghostty.connect.terminal.bridge.GhosttyTerminal
import dev.ghostty.connect.terminal.view.GhosttyTerminalView
import java.util.UUID

class MainActivity : Activity() {
    private lateinit var hostStore: HostStore
    private lateinit var keyStore: SshKeyStore
    private var sessionService: SshSessionService? = null
    private var sessionBound = false
    private var shouldBindSession = false
    private var pendingConnection: Pair<Host, String>? = null
    private var terminalStatus: TextView? = null
    private var terminalView: GhosttyTerminalView? = null
    private var previewTerminal: GhosttyTerminal? = null
    private var editingHostId: String? = null
    private var editorKeySelection: Spinner? = null
    private val surface = Color.rgb(17, 19, 24)
    private val raised = Color.rgb(26, 29, 36)
    private val primary = Color.rgb(241, 243, 248)
    private val secondary = Color.rgb(174, 182, 198)
    private val accent = Color.rgb(139, 233, 179)
    private val sessionListener = object : SshSessionService.Listener {
        override fun onSessionStatus(status: String) {
            val service = sessionService ?: return
            terminalStatus?.text = "$status · ${service.host?.destination.orEmpty()}"
            setTerminalEnabled(status == "Connected")
        }

        override fun onTerminalChanged() {
            terminalView?.refresh()
        }

        override fun onHostKeyVerification(fingerprint: String, changed: Boolean, answer: (Boolean) -> Unit) {
            AlertDialog.Builder(this@MainActivity)
                .setTitle(if (changed) "Host key changed" else "Unknown host")
                .setMessage((if (changed) "The saved host key does not match. This could indicate an attack.\n\n" else "Verify this fingerprint with the server administrator:\n\n") + fingerprint)
                .setNegativeButton("Reject") { _, _ -> answer(false) }
                .setPositiveButton(if (changed) "Accept new key" else "Trust host") { _, _ -> answer(true) }
                .setOnCancelListener { answer(false) }
                .show()
        }

        override fun onSessionClosed(error: String?) {
            terminalStatus?.text = if (error == null) "Disconnected" else "Connection failed"
            setTerminalEnabled(false)
        }
    }
    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            val service = (binder as SshSessionService.LocalBinder).service
            sessionService = service
            sessionBound = true
            service.attach(sessionListener)
            pendingConnection?.let { (host, credential) ->
                pendingConnection = null
                service.connect(host, credential)
            }
            service.host?.let { renderTerminal(service) }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            sessionBound = false
            sessionService = null
            setTerminalEnabled(false)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.decorView.setOnApplyWindowInsetsListener { view, insets ->
            val bars = if (android.os.Build.VERSION.SDK_INT >= 30) {
                insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.ime())
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
        shouldBindSession = intent?.action == SshSessionService.ACTION_OPEN_SESSION || SshSessionService.active
        showHosts(disconnect = false)
        if (Build.VERSION.SDK_INT >= 33) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT) {
                handleBackNavigation()
            }
        }
    }

    override fun onStart() {
        super.onStart()
        if (shouldBindSession && !sessionBound) bindSessionService()
    }

    override fun onStop() {
        if (sessionBound) {
            sessionService?.detach(sessionListener)
            unbindService(serviceConnection)
            sessionBound = false
            sessionService = null
        }
        super.onStop()
    }

    private fun showHosts(disconnect: Boolean = true) {
        editingHostId = null
        if (disconnect) {
            sessionService?.disconnect()
            shouldBindSession = false
        }
        terminalStatus = null
        terminalView = null
        editorKeySelection = null
        previewTerminal?.close()
        previewTerminal = null
        val root = vertical(24)
        root.addView(label("Ghostty Connect", 28f, primary, Typeface.BOLD))
        root.addView(label("A fast, native SSH terminal", 15f, secondary).margins(bottom = 28))
        val hosts = hostStore.loadAll()
        hosts.forEach { host ->
            val card = vertical(18).apply { setBackgroundColor(raised) }
            card.addView(label(host.name, 20f, primary, Typeface.BOLD))
            card.addView(label(host.destination, 14f, secondary))
            card.addView(label(host.keyName?.let { "SSH key · $it" } ?: "Password", 14f, accent).margins(top = 8))
            card.addView(button("Edit", secondary) { showHostEditor(host.id) }.margins(top = 10))
            card.setOnClickListener { requestCredentialAndConnect(host) }
            root.addView(card.margins(bottom = 16))
        }
        root.addView(button(if (hosts.isEmpty()) "Add your first host" else "Add host") { showHostEditor() })
        root.addView(button("Import SSH key", secondary) { openKeyPicker() }.margins(top = 10))
        root.addView(button("Paste private key", secondary) { showPasteKeyDialog() }.margins(top = 10))
        root.addView(button("Ghostty renderer preview", secondary) { showGhosttyPreview() }.margins(top = 10))
        if (keyStore.names().isNotEmpty()) {
            root.addView(label("Imported keys: ${keyStore.names().joinToString()}", 13f, secondary).margins(top = 14))
        }
        setContentView(scroll(root))
    }

    private fun showHostEditor(hostId: String? = null) {
        editingHostId = hostId
        val existing = hostStore.loadAll().firstOrNull { it.id == hostId }
        val root = vertical(24)
        root.addView(label(if (existing == null) "New connection" else "Edit connection", 28f, primary, Typeface.BOLD))
        val alias = field("Alias (optional)", existing?.alias.orEmpty())
        val hostname = field("Hostname or IP", existing?.hostname.orEmpty())
        val username = field("User", existing?.username.orEmpty())
        val port = field("Port", existing?.port?.toString() ?: "22", InputType.TYPE_CLASS_NUMBER)
        listOf(alias, hostname, username, port).forEach { root.addView(it.margins(bottom = 12)) }

        root.addView(label("Authentication", 14f, secondary).margins(top = 6, bottom = 6))
        val authenticationChoices = listOf("Password", "SSH key")
        val authentication = Spinner(this).apply {
            adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_dropdown_item, authenticationChoices)
            setBackgroundColor(raised)
            setSelection(if (existing?.authenticationType == AuthenticationType.SSH_KEY) 1 else 0)
        }
        root.addView(authentication.margins(bottom = 10))

        val keyNames = keyStore.names()
        val keySelection = Spinner(this).apply {
            adapter = ArrayAdapter(
                this@MainActivity,
                android.R.layout.simple_spinner_dropdown_item,
                keyNames.ifEmpty { listOf("No SSH keys saved") },
            )
            setBackgroundColor(raised)
            setSelection(keyNames.indexOf(existing?.keyName).coerceAtLeast(0))
        }.also { editorKeySelection = it }
        val addKey = button("Add SSH key", secondary) { openKeyPicker() }
        fun updateKeyControls() {
            val visible = if (authentication.selectedItemPosition == 1) View.VISIBLE else View.GONE
            keySelection.visibility = visible
            addKey.visibility = visible
        }
        authentication.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) = updateKeyControls()
            override fun onNothingSelected(parent: AdapterView<*>?) = Unit
        }
        root.addView(keySelection.margins(bottom = 10))
        root.addView(addKey.margins(bottom = 16))
        updateKeyControls()
        root.addView(button("Save host") {
            val parsedPort = port.text.toString().toIntOrNull()
            if (hostname.text.isBlank() || username.text.isBlank() || parsedPort !in 1..65535) {
                toast("Enter a hostname, username, and valid port.")
                return@button
            }
            val authenticationType = if (authentication.selectedItemPosition == 1) {
                AuthenticationType.SSH_KEY
            } else {
                AuthenticationType.PASSWORD
            }
            if (authenticationType == AuthenticationType.SSH_KEY && keyStore.names().isEmpty()) {
                toast("Add an SSH key before saving this host.")
                return@button
            }
            hostStore.save(Host(
                id = existing?.id ?: UUID.randomUUID().toString(),
                alias = alias.text.toString().trim().ifBlank { null },
                hostname = hostname.text.toString().trim(),
                port = parsedPort!!,
                username = username.text.toString().trim(),
                authenticationType = authenticationType,
                keyName = keySelection.selectedItem.toString().takeIf { authenticationType == AuthenticationType.SSH_KEY },
            ))
            editingHostId = null
            showHosts()
        })
        root.addView(button("Paste a private key", secondary) { showPasteKeyDialog() }.margins(top = 8))
        existing?.let { host ->
            root.addView(button("Delete host", secondary) {
                hostStore.delete(host.id)
                editingHostId = null
                showHosts()
            }.margins(top = 8))
        }
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
                    refreshEditorKeys(name.text.toString().trim().ifBlank { "Pasted key" })
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
            refreshEditorKeys(displayName)
        } catch (error: Exception) {
            toast(error.message ?: "Could not import key")
        }
    }

    private fun requestCredentialAndConnect(host: Host) {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_PERMISSION)
        }
        if (host.authenticationType == AuthenticationType.SSH_KEY) {
            startSession(host, "")
            return
        }
        val credential = field("Password", "", InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
        AlertDialog.Builder(this)
            .setTitle("Authenticate")
            .setView(credential)
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Connect") { _, _ -> startSession(host, credential.text.toString()) }
            .show()
    }

    private fun refreshEditorKeys(selectedName: String) {
        val spinner = editorKeySelection
        if (spinner == null) {
            showHostEditor(editingHostId)
            return
        }
        val names = keyStore.names()
        spinner.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, names)
        spinner.setSelection(names.indexOf(selectedName).coerceAtLeast(0))
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

    private fun startSession(host: Host, credential: String) {
        pendingConnection = host to credential
        shouldBindSession = true
        startForegroundService(Intent(this, SshSessionService::class.java))
        if (!sessionBound) bindSessionService() else {
            pendingConnection = null
            sessionService?.let { service ->
                service.connect(host, credential)
                renderTerminal(service)
            }
        }
    }

    private fun bindSessionService() {
        bindService(Intent(this, SshSessionService::class.java), serviceConnection, Context.BIND_AUTO_CREATE)
    }

    private fun renderTerminal(service: SshSessionService) {
        val host = service.host ?: return
        val terminal = service.terminal ?: return
        val root = vertical(0)
        val status = label("Connecting…", 13f, accent).also { terminalStatus = it }
        val toolbar = vertical(16).apply { setBackgroundColor(raised) }
        val titleRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        titleRow.addView(label(host.name, 18f, primary, Typeface.BOLD), LinearLayout.LayoutParams(0, -2, 1f))
        val overflow = label("...", 24f, primary).apply {
            contentDescription = "More options"
            gravity = Gravity.CENTER
            setPadding(dp(12), dp(4), dp(12), dp(4))
            setOnClickListener { anchor ->
                PopupMenu(this@MainActivity, anchor).apply {
                    menu.add("Disconnect")
                    setOnMenuItemClickListener { item ->
                        if (item.title == "Disconnect") {
                            showHosts()
                            true
                        } else {
                            false
                        }
                    }
                    show()
                }
            }
        }
        titleRow.addView(overflow, LinearLayout.LayoutParams(dp(48), -2))
        toolbar.addView(titleRow)
        toolbar.addView(status)
        root.addView(toolbar)

        val view = GhosttyTerminalView(this, terminal).apply {
            isEnabled = false
            onInput = { sessionService?.send(it) }
            onResize = { columns, rows, pixelWidth, pixelHeight ->
                sessionService?.resize(columns, rows, pixelWidth, pixelHeight)
            }
        }.also { terminalView = it }
        root.addView(view, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(root)
        sessionListener.onSessionStatus(service.run { statusText() })
    }

    private fun setTerminalEnabled(enabled: Boolean) {
        terminalView?.isEnabled = enabled
        if (enabled) terminalView?.requestFocus()
    }

    private fun handleBackNavigation() {
        if (terminalView != null || previewTerminal != null) showHosts() else finish()
    }

    @SuppressLint("GestureBackNavigation")
    @Deprecated("Fallback for Android 10 through 12")
    override fun onBackPressed() = handleBackNavigation()

    override fun onDestroy() {
        previewTerminal?.close()
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

    companion object {
        const val IMPORT_KEY = 1001
        const val NOTIFICATION_PERMISSION = 1002
    }
}
