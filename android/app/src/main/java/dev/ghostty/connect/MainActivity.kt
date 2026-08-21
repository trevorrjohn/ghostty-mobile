package dev.ghostty.connect

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.annotation.SuppressLint
import android.content.Intent
import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.ClipboardManager
import android.content.ClipData
import android.graphics.Color
import android.graphics.Rect
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Build
import android.os.Looper
import android.content.pm.PackageManager
import android.text.InputType
import android.text.Editable
import android.text.TextWatcher
import android.view.Gravity
import android.view.KeyEvent
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowManager
import android.window.OnBackInvokedDispatcher
import android.widget.ArrayAdapter
import android.widget.AdapterView
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import dev.ghostty.connect.data.HostStore
import dev.ghostty.connect.data.KeyboardBarStore
import dev.ghostty.connect.data.SshKeyStore
import dev.ghostty.connect.data.TerminalThemeStore
import dev.ghostty.connect.data.TerminalStateStore
import dev.ghostty.connect.model.AuthenticationType
import dev.ghostty.connect.model.Host
import dev.ghostty.connect.model.duplicate
import dev.ghostty.connect.model.KeyboardBarCatalog
import dev.ghostty.connect.model.KeyboardBarConfig
import dev.ghostty.connect.model.KeyboardBarItem
import dev.ghostty.connect.model.KeyboardBarItemType
import dev.ghostty.connect.model.KeyboardModifier
import dev.ghostty.connect.model.TerminalThemes
import dev.ghostty.connect.terminal.SshSessionService
import dev.ghostty.connect.terminal.AuthenticationChallenge
import dev.ghostty.connect.terminal.bridge.GhosttyTerminal
import dev.ghostty.connect.terminal.bridge.TerminalEffects
import dev.ghostty.connect.terminal.view.GhosttyTerminalView
import net.schmizz.sshj.connection.channel.direct.Signal
import java.util.UUID

class MainActivity : Activity() {
    private lateinit var hostStore: HostStore
    private lateinit var keyStore: SshKeyStore
    private lateinit var keyboardBarStore: KeyboardBarStore
    private lateinit var terminalThemeStore: TerminalThemeStore
    private lateinit var terminalStateStore: TerminalStateStore
    private var keyboardBarConfig = KeyboardBarConfig()
    private var sessionService: SshSessionService? = null
    private var sessionBound = false
    private var shouldBindSession = false
    private data class PendingConnection(val sessionId: String, val host: Host, val credential: CharArray)

    private var pendingConnection: PendingConnection? = null
    private var selectedSessionId: String? = null
    private var terminalStatus: TextView? = null
    private var terminalTitle: TextView? = null
    private var terminalRetryButton: Button? = null
    private var terminalView: GhosttyTerminalView? = null
    private var shellIntegrationNotice: View? = null
    private var shellIntegrationNoticeRunnable: Runnable? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var previewTerminal: GhosttyTerminal? = null
    private var editingHostId: String? = null
    private var editorKeySelection: Spinner? = null
    private var editorAuthentication: Spinner? = null
    private var modifierBar: View? = null
    private var modifierBarRow: LinearLayout? = null
    private var imeVisible = false
    private var terminalAtBottom = true
    private var settingsVisible = false
    private var terminalSearchQuery = ""
    private val activeModifiers = mutableSetOf<KeyboardModifier>()
    private val lockedModifiers = mutableSetOf<KeyboardModifier>()
    private var lastUsedModifier: KeyboardModifier? = null
    private var lastUsedCombination: KeyboardBarItem? = null
    private val surface = Color.rgb(17, 19, 24)
    private val raised = Color.rgb(26, 29, 36)
    private val primary = Color.rgb(241, 243, 248)
    private val secondary = Color.rgb(174, 182, 198)
    private val accent = Color.rgb(139, 233, 179)
    private val sessionListener = object : SshSessionService.Listener {
        override fun onSessionStatus(sessionId: String, status: String) {
            if (sessionId != selectedSessionId) return
            val service = sessionService ?: return
            terminalStatus?.text = "$status · ${service.host(sessionId)?.destination.orEmpty()}"
            setTerminalEnabled(status == "Connected")
            terminalRetryButton?.visibility = if (
                service.summaries().firstOrNull { it.sessionId == sessionId }?.canRetry == true
            ) View.VISIBLE else View.GONE
            if (status == "Connected") scheduleShellIntegrationNotice(sessionId)
            else cancelShellIntegrationNotice()
        }

        override fun onTerminalChanged(sessionId: String) {
            if (sessionId != selectedSessionId) return
            terminalView?.refresh()
        }

        override fun onTerminalEffects(sessionId: String, effects: TerminalEffects) {
            if (sessionId != selectedSessionId) return
            if (effects.bells > 0) terminalView?.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            if (effects.progressState >= 0 && effects.progress >= 0) {
                terminalStatus?.text = "${effects.progress}% · ${sessionService?.host(sessionId)?.destination.orEmpty()}"
            }
            if (effects.clipboard.isNotEmpty()) handleRemoteClipboard(effects.clipboard)
            if (effects.notificationTitle.isNotEmpty() || effects.notificationBody.isNotEmpty()) {
                handleRemoteNotification(effects.notificationTitle, effects.notificationBody)
            }
            if (effects.processingError) terminalStatus?.text = "Terminal processing warning"
        }

        override fun onHostKeyVerification(
            sessionId: String,
            fingerprint: String,
            changed: Boolean,
            answer: (Boolean) -> Unit,
        ) {
            val hostName = sessionService?.host(sessionId)?.name
            AlertDialog.Builder(this@MainActivity)
                .setTitle(if (changed) "Host key changed" else "Unknown host")
                .setMessage((hostName?.let { "$it\n\n" } ?: "") + (if (changed) "The saved host key does not match. This could indicate an attack.\n\n" else "Verify this fingerprint with the server administrator:\n\n") + fingerprint)
                .setNegativeButton("Reject") { _, _ -> answer(false) }
                .setPositiveButton(if (changed) "Accept new key" else "Trust host") { _, _ -> answer(true) }
                .setOnCancelListener { answer(false) }
                .show()
        }

        override fun onAuthenticationChallenge(
            sessionId: String,
            hostName: String,
            challenge: AuthenticationChallenge,
            answer: (CharArray?) -> Unit,
        ) {
            val response = field(
                challenge.prompt.ifBlank { "Response" },
                "",
                if (challenge.echo) InputType.TYPE_CLASS_TEXT else {
                    InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
                },
            )
            val message = listOf(challenge.instruction, challenge.prompt)
                .filter(String::isNotBlank)
                .joinToString("\n\n")
            AlertDialog.Builder(this@MainActivity)
                .setTitle(challenge.title.ifBlank { "Authenticate with $hostName" })
                .setMessage("$hostName · session ${sessionId.take(8)}" + if (message.isBlank()) "" else "\n\n$message")
                .setView(response)
                .setNegativeButton("Cancel") { _, _ ->
                    response.text.clear()
                    answer(null)
                }
                .setPositiveButton("Respond") { _, _ ->
                    val value = response.text.toString().toCharArray()
                    response.text.clear()
                    answer(value)
                }
                .setOnCancelListener {
                    response.text.clear()
                    answer(null)
                }
                .show()
        }

        override fun onSessionClosed(sessionId: String, error: String?) {
            if (sessionId != selectedSessionId) return
            val retryable = sessionService?.summaries()?.firstOrNull { it.sessionId == sessionId }?.canRetry == true
            if (!retryable) terminalStatus?.text = if (error == null) "Disconnected" else "Connection failed"
            setTerminalEnabled(false)
        }
    }
    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            val service = (binder as SshSessionService.LocalBinder).service
            sessionService = service
            sessionBound = true
            service.attach(sessionListener, selectedSessionId)
            pendingConnection?.let { pending ->
                pendingConnection = null
                service.connect(pending.sessionId, pending.host, pending.credential)
                selectedSessionId = pending.sessionId
                service.selectListenerSession(pending.sessionId)
            }
            val requested = selectedSessionId?.takeIf { service.host(it) != null }
            val sessionId = requested ?: service.summaries().singleOrNull()?.sessionId
            if (sessionId != null) openSession(sessionId) else showHosts(disconnect = false)
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
                imeVisible = insets.isVisible(WindowInsets.Type.ime())
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
            updateModifierBarVisibility()
            insets
        }
        if (Build.VERSION.SDK_INT < 30) {
            window.decorView.viewTreeObserver.addOnGlobalLayoutListener {
                val visible = Rect()
                window.decorView.getWindowVisibleDisplayFrame(visible)
                imeVisible = window.decorView.rootView.height - visible.bottom > window.decorView.rootView.height * 0.15
                updateModifierBarVisibility()
            }
        }
        hostStore = HostStore(this)
        keyStore = SshKeyStore(this)
        keyboardBarStore = KeyboardBarStore(this)
        terminalThemeStore = TerminalThemeStore(this)
        terminalStateStore = TerminalStateStore(this)
        keyboardBarConfig = keyboardBarStore.load()
        selectedSessionId = intent?.getStringExtra(SshSessionService.EXTRA_SESSION_ID)
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

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        setIntent(intent)
        val sessionId = intent?.takeIf { it.action == SshSessionService.ACTION_OPEN_SESSION }
            ?.getStringExtra(SshSessionService.EXTRA_SESSION_ID) ?: return
        selectedSessionId = sessionId
        shouldBindSession = true
        sessionService?.let { if (it.host(sessionId) != null) openSession(sessionId) }
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

    private fun showHosts(disconnect: Boolean = false) {
        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        editingHostId = null
        settingsVisible = false
        if (disconnect) {
            selectedSessionId?.let { sessionService?.disconnect(it) }
        }
        selectedSessionId = null
        sessionService?.selectListenerSession(null)
        terminalStatus = null
        terminalTitle = null
        terminalRetryButton = null
        terminalView = null
        shellIntegrationNotice = null
        cancelShellIntegrationNotice()
        editorKeySelection = null
        editorAuthentication = null
        modifierBar = null
        modifierBarRow = null
        previewTerminal?.close()
        previewTerminal = null
        val root = vertical(24)
        root.addView(label("Ghostty Connect", 28f, primary, Typeface.BOLD))
        root.addView(label("A fast, native SSH terminal", 15f, secondary).margins(bottom = 28))
        val activeSessions = sessionService?.summaries().orEmpty()
        if (activeSessions.isNotEmpty()) {
            root.addView(label("Active sessions", 20f, primary, Typeface.BOLD).margins(bottom = 10))
            activeSessions.forEach { session ->
                val row = vertical(12).apply { setBackgroundColor(raised) }
                row.addView(label(session.hostName, 17f, primary, Typeface.BOLD))
                row.addView(label("${session.status} · ${session.destination}", 13f, secondary))
                val actions = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
                actions.addView(compactButton("Open") { openSession(session.sessionId) })
                sessionService?.host(session.sessionId)?.let { host ->
                    actions.addView(compactButton("Duplicate session") { requestCredentialAndConnect(host) })
                }
                if (session.canRetry) {
                    actions.addView(compactButton("Retry / Reauthenticate") { reauthenticate(session.sessionId) })
                }
                actions.addView(compactButton("Disconnect") {
                    sessionService?.disconnect(session.sessionId)
                    showHosts(disconnect = false)
                })
                row.addView(actions.margins(top = 8))
                root.addView(row.margins(bottom = 12))
            }
            root.addView(label("Hosts", 20f, primary, Typeface.BOLD).margins(top = 12, bottom = 10))
        }
        val hosts = hostStore.loadAll()
        hosts.forEach { host ->
            val card = vertical(18).apply { setBackgroundColor(raised) }
            card.addView(label(host.name, 20f, primary, Typeface.BOLD))
            card.addView(label(host.destination, 14f, secondary))
            card.addView(label(host.keyName?.let { "SSH key · $it" } ?: "Password", 14f, accent).margins(top = 8))
            card.addView(button("Edit", secondary) { showHostEditor(host.id) }.margins(top = 10))
            card.addView(button("Duplicate host", secondary) {
                val duplicate = host.duplicate(UUID.randomUUID().toString(), hosts.map(Host::name))
                hostStore.save(duplicate)
                toast("Created ${duplicate.name}")
                showHosts()
            }.margins(top = 8))
            if (terminalStateStore.has(host.id)) {
                card.addView(button("Last session", secondary) { showArchivedTerminal(host) }.margins(top = 8))
            }
            card.setOnClickListener { requestCredentialAndConnect(host) }
            root.addView(card.margins(bottom = 16))
        }
        root.addView(button(if (hosts.isEmpty()) "Add your first host" else "Add host") { showHostEditor() })
        root.addView(button("Import SSH key", secondary) { openKeyPicker() }.margins(top = 10))
        root.addView(button("Paste private key", secondary) { showPasteKeyDialog() }.margins(top = 10))
        root.addView(button("Settings", secondary) { showKeyboardSettings() }.margins(top = 10))
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
        }.also { editorAuthentication = it }
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

        root.addView(label("Remote requests", 14f, secondary).margins(top = 6, bottom = 6))
        val policyChoices = listOf("Ask first time", "Allow", "Block")
        fun policySpinner(label: String, value: Boolean?): Spinner {
            root.addView(this.label(label, 13f, secondary).margins(bottom = 4))
            return Spinner(this).apply {
                adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_dropdown_item, policyChoices)
                setBackgroundColor(raised)
                setSelection(when (value) { true -> 1; false -> 2; null -> 0 })
                root.addView(this.margins(bottom = 10))
            }
        }
        val clipboardPolicy = policySpinner("Clipboard writes", existing?.allowRemoteClipboard)
        val notificationPolicy = policySpinner("Terminal notifications", existing?.allowRemoteNotifications)
        fun selectedPolicy(spinner: Spinner): Boolean? = when (spinner.selectedItemPosition) {
            1 -> true
            2 -> false
            else -> null
        }
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
                allowRemoteClipboard = selectedPolicy(clipboardPolicy),
                allowRemoteNotifications = selectedPolicy(notificationPolicy),
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
        val encryptionStatus = label("", 13f, secondary)
        var generatedName = ""
        privateKey.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(value: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(value: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(value: Editable?) {
                val keyBytes = value.toString().trim().toByteArray()
                if (keyBytes.isEmpty()) {
                    encryptionStatus.text = ""
                    return
                }
                val details = keyStore.inspect(keyBytes)
                if (name.text.isBlank() || name.text.toString() == generatedName) {
                    generatedName = details.suggestedName
                    name.setText(generatedName)
                }
                encryptionStatus.text = if (details.requiresPassphrase) {
                    "Encrypted key · passphrase required when connecting"
                } else {
                    "No key passphrase detected"
                }
            }
        })
        form.addView(name.margins(bottom = 10))
        form.addView(privateKey, LinearLayout.LayoutParams(-1, dp(260)))
        form.addView(encryptionStatus.margins(top = 8))
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
                    val bytes = (value + "\n").toByteArray()
                    val savedName = name.text.toString().trim().ifBlank { keyStore.inspect(bytes).suggestedName }
                    keyStore.import(savedName, bytes)
                    privateKey.text.clear()
                    dialog.dismiss()
                    toast("Private key saved")
                    refreshEditorKeys(savedName)
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

    private fun requestCredentialAndConnect(host: Host) = requestCredential(host) { credential ->
        startSession(host, credential)
    }

    private fun requestCredential(host: Host, connect: (CharArray) -> Unit) {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_PERMISSION)
        }
        if (host.authenticationType == AuthenticationType.SSH_KEY) {
            val keyName = requireNotNull(host.keyName)
            if (!keyStore.requiresPassphrase(keyName)) {
                connect(CharArray(0))
                return
            }
            val passphrase = field(
                "Private key passphrase",
                "",
                InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD,
            )
            val dialog = AlertDialog.Builder(this)
                .setTitle("Unlock $keyName")
                .setView(passphrase)
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Connect", null)
                .create()
            dialog.setOnShowListener {
                dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                    if (passphrase.text.isEmpty()) {
                        toast("Enter the private key passphrase")
                    } else {
                        dialog.dismiss()
                        val value = passphrase.text.toString().toCharArray()
                        passphrase.text.clear()
                        connect(value)
                    }
                }
            }
            dialog.show()
            return
        }
        val credential = field("Password", "", InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
        AlertDialog.Builder(this)
            .setTitle("Authenticate")
            .setView(credential)
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Connect") { _, _ ->
                val value = credential.text.toString().toCharArray()
                credential.text.clear()
                connect(value)
            }
            .show()
    }

    private fun reauthenticate(sessionId: String) {
        val service = sessionService ?: return
        val host = service.host(sessionId) ?: return
        requestCredential(host) { credential ->
            service.retry(sessionId, credential)
            openSession(sessionId)
        }
    }

    private fun refreshEditorKeys(selectedName: String) {
        val spinner = editorKeySelection
        if (spinner == null) {
            showHostEditor(editingHostId)
            refreshEditorKeys(selectedName)
            return
        }
        val names = keyStore.names()
        spinner.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, names)
        spinner.setSelection(names.indexOf(selectedName).coerceAtLeast(0))
        editorAuthentication?.setSelection(1)
    }

    private fun showKeyboardSettings() {
        settingsVisible = true
        val root = vertical(24)
        root.addView(label("Settings", 28f, primary, Typeface.BOLD))

        root.addView(label("Terminal theme", 18f, primary, Typeface.BOLD).margins(bottom = 6))
        val currentTheme = terminalThemeStore.load()
        val themeSpinner = Spinner(this).apply {
            adapter = ArrayAdapter(
                this@MainActivity,
                android.R.layout.simple_spinner_dropdown_item,
                TerminalThemes.all.map { it.name },
            )
            setBackgroundColor(raised)
            setSelection(TerminalThemes.all.indexOfFirst { it.id == currentTheme.id }.coerceAtLeast(0))
            onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                    terminalThemeStore.save(TerminalThemes.all[position])
                }
                override fun onNothingSelected(parent: AdapterView<*>?) = Unit
            }
        }
        root.addView(themeSpinner.margins(bottom = 18))
        val fontSize = field(
            "Font size (9-30)",
            terminalThemeStore.loadFontSize().toInt().toString(),
            InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL,
        )
        root.addView(fontSize.margins(bottom = 8))
        root.addView(button("Save font size", secondary) {
            val size = fontSize.text.toString().toFloatOrNull()
            if (size == null || size !in 9f..30f) toast("Enter a font size from 9 to 30.")
            else {
                terminalThemeStore.saveFontSize(size)
                toast("Font size saved")
            }
        }.margins(bottom = 18))

        root.addView(label("Keyboard bar", 18f, primary, Typeface.BOLD))
        root.addView(label("Shown above the keyboard while the terminal is live.", 14f, secondary).margins(bottom = 12))

        val enabled = CheckBox(this).apply {
            text = "Enable keyboard bar"
            setTextColor(primary)
            isChecked = keyboardBarConfig.enabled
            setOnCheckedChangeListener { _, checked ->
                saveKeyboardBarConfig(keyboardBarConfig.copy(enabled = checked), refreshSettings = false)
            }
        }
        root.addView(enabled.margins(bottom = 14))
        root.addView(label("Preview", 14f, secondary).margins(bottom = 6))
        root.addView(settingsBarPreview().margins(bottom = 18))
        root.addView(label("Order", 18f, primary, Typeface.BOLD).margins(bottom = 8))

        keyboardBarConfig.items.forEachIndexed { index, item ->
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setBackgroundColor(raised)
                setPadding(dp(12), dp(6), dp(6), dp(6))
            }
            row.addView(label(item.label, 15f, primary), LinearLayout.LayoutParams(0, -2, 1f))
            row.addView(compactButton("Up", index > 0) { moveKeyboardBarItem(index, index - 1) })
            row.addView(compactButton("Down", index < keyboardBarConfig.items.lastIndex) { moveKeyboardBarItem(index, index + 1) })
            row.addView(compactButton("Remove") {
                saveKeyboardBarConfig(keyboardBarConfig.copy(items = keyboardBarConfig.items.filterIndexed { i, _ -> i != index }))
            })
            root.addView(row.margins(bottom = 6))
        }

        root.addView(button("Add item") { showAddKeyboardBarItem() }.margins(top = 10))
        root.addView(button("Create combination", secondary) { showCombinationEditor() }.margins(top = 8))
        if (keyboardBarConfig.combinations.isNotEmpty()) {
            root.addView(label("Saved combinations", 18f, primary, Typeface.BOLD).margins(top = 18, bottom = 8))
            keyboardBarConfig.combinations.forEach { combination ->
                val row = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    setBackgroundColor(raised)
                    setPadding(dp(12), dp(6), dp(6), dp(6))
                }
                row.addView(label(combination.label, 15f, primary), LinearLayout.LayoutParams(0, -2, 1f))
                row.addView(compactButton("Edit") { showCombinationEditor(combination) })
                row.addView(compactButton("Delete") {
                    saveKeyboardBarConfig(keyboardBarConfig.copy(
                        items = keyboardBarConfig.items.filterNot { it.id == combination.id },
                        combinations = keyboardBarConfig.combinations.filterNot { it.id == combination.id },
                    ))
                })
                root.addView(row.margins(bottom = 6))
            }
        }
        root.addView(button("Reset to defaults", secondary) {
            saveKeyboardBarConfig(keyboardBarConfig.copy(items = KeyboardBarCatalog.defaultItems))
        }.margins(top = 8))
        root.addView(button("Back", secondary) { showHosts(disconnect = false) }.margins(top = 16))
        setContentView(scroll(root))
    }

    private fun settingsBarPreview(): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(4), dp(4), dp(4), dp(4))
        }
        keyboardBarConfig.items.forEach { row.addView(barButton(it.label) {}) }
        row.addView(barButton("More") {})
        return HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            setBackgroundColor(raised)
            addView(row, ViewGroup.LayoutParams(-2, dp(48)))
        }
    }

    private fun moveKeyboardBarItem(from: Int, to: Int) {
        if (to !in keyboardBarConfig.items.indices) return
        val items = keyboardBarConfig.items.toMutableList()
        val item = items.removeAt(from)
        items.add(to, item)
        saveKeyboardBarConfig(keyboardBarConfig.copy(items = items))
    }

    private fun showAddKeyboardBarItem() {
        val currentIds = keyboardBarConfig.items.mapTo(mutableSetOf(), KeyboardBarItem::id)
        val available = (KeyboardBarCatalog.availableItems + keyboardBarConfig.combinations)
            .filterNot { it.id in currentIds }
        if (available.isEmpty()) {
            toast("All available items are already in the bar.")
            return
        }
        AlertDialog.Builder(this)
            .setTitle("Add keyboard item")
            .setItems(available.map(KeyboardBarItem::label).toTypedArray()) { _, index ->
                saveKeyboardBarConfig(keyboardBarConfig.copy(items = keyboardBarConfig.items + available[index]))
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun showCombinationEditor(existing: KeyboardBarItem? = null) {
        val form = vertical(16)
        val name = field("Label (optional)", existing?.label.orEmpty())
        val key = field("Key, for example b or ARROW_LEFT", existing?.key.orEmpty())
        form.addView(name.margins(bottom = 8))
        form.addView(key.margins(bottom = 10))
        form.addView(label("Modifiers", 14f, secondary).margins(bottom = 4))
        val checks = KeyboardModifier.entries.associateWith { modifier ->
            CheckBox(this).apply {
                text = modifier.displayName
                setTextColor(primary)
                isChecked = existing?.modifiers?.contains(modifier) == true
                form.addView(this)
            }
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle("Custom combination")
            .setView(scroll(form))
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Save", null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val keyValue = key.text.toString().trim()
                val modifiers = checks.filterValues(CheckBox::isChecked).keys
                if (keyValue.isBlank() || modifiers.isEmpty()) {
                    toast("Choose at least one modifier and enter a key.")
                    return@setOnClickListener
                }
                val labelValue = name.text.toString().trim().ifBlank {
                    (modifiers.joinToString("+") { it.displayName }) + "+" + keyValue
                }
                val combination = KeyboardBarItem(
                    id = existing?.id ?: "combination-${UUID.randomUUID()}",
                    label = labelValue,
                    type = KeyboardBarItemType.COMBINATION,
                    key = keyValue.uppercase().takeIf { candidate ->
                        KeyboardBarCatalog.keys.any { it.key == candidate }
                    } ?: keyValue,
                    modifiers = modifiers,
                )
                val items = if (existing == null) {
                    keyboardBarConfig.items + combination
                } else {
                    keyboardBarConfig.items.map { if (it.id == existing.id) combination else it }
                }
                val combinations = if (existing == null) {
                    keyboardBarConfig.combinations + combination
                } else {
                    keyboardBarConfig.combinations.map { if (it.id == existing.id) combination else it }
                }
                saveKeyboardBarConfig(keyboardBarConfig.copy(items = items, combinations = combinations))
                dialog.dismiss()
            }
        }
        dialog.show()
    }

    private fun saveKeyboardBarConfig(config: KeyboardBarConfig, refreshSettings: Boolean = true) {
        keyboardBarConfig = config
        keyboardBarStore.save(config)
        if (refreshSettings) showKeyboardSettings()
    }

    private fun showGhosttyPreview() {
        val theme = terminalThemeStore.load()
        val terminal = GhosttyTerminal(
            foreground = theme.foreground,
            background = theme.background,
            cursor = theme.cursor,
            palette = theme.palette,
        ).also { previewTerminal = it }
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
                "~ ❯ " +
                "\u001b_Ga=T,f=100,q=2,c=8,r=4;" +
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==" +
                "\u001b\\",
        )
        val root = vertical(0)
        val toolbar = vertical(16).apply { setBackgroundColor(raised) }
        toolbar.addView(label("Ghostty renderer", 18f, primary, Typeface.BOLD))
        toolbar.addView(label("Recorded native terminal fixture", 13f, accent))
        root.addView(toolbar)
        root.addView(
            GhosttyTerminalView(this, terminal, terminalThemeStore.loadFontSize()).apply {
                onTextSizeChanged = terminalThemeStore::saveFontSize
            },
            LinearLayout.LayoutParams(-1, 0, 1f),
        )
        root.addView(button("Back to hosts", secondary) { showHosts() })
        setContentView(root)
    }

    private fun showArchivedTerminal(host: Host) {
        val terminal = runCatching {
            GhosttyTerminal(restoredState = terminalStateStore.load(host.id))
        }.getOrElse {
            toast("Could not restore the last terminal session.")
            return
        }.also { previewTerminal = it }
        val root = vertical(0)
        val toolbar = vertical(16).apply { setBackgroundColor(raised) }
        toolbar.addView(label(host.name, 18f, primary, Typeface.BOLD))
        toolbar.addView(label("Last session · read-only", 13f, secondary))
        root.addView(toolbar)
        val view = GhosttyTerminalView(this, terminal, terminalThemeStore.loadFontSize()).apply {
            isEnabled = true
            acceptsInput = false
            isMouseTracking = { false }
            onSelectionStart = terminal::selectWord
            onSelectionUpdate = { start, column, row -> terminal.setSelectionEndpoint(start, column, row) }
            onSelectionFinished = {
                terminal.selectedText().takeIf(String::isNotEmpty)?.let { writeClipboard(it) }
            }
            onLinkTap = { column, row ->
                val uri = terminal.hyperlink(column, row).takeIf { it.isNotBlank() }?.let(Uri::parse)
                if (uri?.scheme in setOf("http", "https")) {
                    startActivity(Intent(Intent.ACTION_VIEW, uri))
                    true
                } else false
            }
        }
        root.addView(view, LinearLayout.LayoutParams(-1, 0, 1f))
        root.addView(button("Back", secondary) { showHosts(disconnect = false) })
        setContentView(root)
    }

    private fun startSession(host: Host, credential: CharArray) {
        val sessionId = SshSessionService.newSessionId()
        selectedSessionId = sessionId
        pendingConnection = PendingConnection(sessionId, host, credential)
        shouldBindSession = true
        startForegroundService(Intent(this, SshSessionService::class.java))
        if (!sessionBound) bindSessionService() else {
            pendingConnection = null
            val service = sessionService
            if (service == null) credential.fill('\u0000') else {
                service.connect(sessionId, host, credential)
                openSession(sessionId)
            }
        }
    }

    private fun bindSessionService() {
        bindService(Intent(this, SshSessionService::class.java), serviceConnection, Context.BIND_AUTO_CREATE)
    }

    private fun openSession(sessionId: String) {
        val service = sessionService ?: return
        selectedSessionId = sessionId
        service.selectListenerSession(sessionId)
        renderTerminal(service, sessionId)
    }

    private fun renderTerminal(service: SshSessionService, sessionId: String) {
        val host = service.host(sessionId) ?: return
        val terminal = service.terminal(sessionId) ?: return
        activeModifiers.clear()
        lockedModifiers.clear()
        terminalAtBottom = true
        settingsVisible = false
        val root = vertical(0)
        val status = label("Connecting…", 13f, accent).also { terminalStatus = it }
        val toolbar = vertical(16).apply { setBackgroundColor(raised) }
        val titleRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        titleRow.addView(
            label(host.name, 18f, primary, Typeface.BOLD).also { terminalTitle = it },
            LinearLayout.LayoutParams(0, -2, 1f),
        )
        val overflow = label("...", 24f, primary).apply {
            contentDescription = "More options"
            gravity = Gravity.CENTER
            setPadding(dp(12), dp(4), dp(12), dp(4))
            setOnClickListener { anchor ->
                PopupMenu(this@MainActivity, anchor).apply {
                    menu.add("Sessions")
                    menu.add("Duplicate session")
                    menu.add("Disconnect")
                    menu.add("Paste")
                    menu.add("Copy latest output")
                    menu.add("Previous prompt")
                    menu.add("Next prompt")
                    menu.add("Search scrollback")
                    menu.add("Shell integration setup")
                    menu.add("Send interrupt signal")
                    menu.add("Send terminate signal")
                    setOnMenuItemClickListener { item ->
                        when (item.title) {
                            "Sessions" -> {
                                showHosts(disconnect = false)
                                true
                            }
                            "Duplicate session" -> {
                                requestCredentialAndConnect(host)
                                true
                            }
                            "Disconnect" -> {
                                service.disconnect(sessionId)
                                showHosts(disconnect = false)
                                true
                            }
                            "Paste" -> {
                                pasteFromClipboard(service)
                                true
                            }
                            "Copy latest output" -> {
                                if (terminal.selectLatestOutput()) {
                                    terminalView?.refresh()
                                    writeClipboard(terminal.selectedText())
                                    toast("Latest output copied")
                                } else toast("No command output found")
                                true
                            }
                            "Previous prompt" -> {
                                if (!terminal.jumpPrompt(-1)) toast("No previous prompt")
                                terminalView?.refresh()
                                true
                            }
                            "Next prompt" -> {
                                if (!terminal.jumpPrompt(1)) toast("No next prompt")
                                terminalView?.refresh()
                                true
                            }
                            "Search scrollback" -> {
                                showScrollbackSearch(terminal)
                                true
                            }
                            "Shell integration setup" -> {
                                showShellIntegrationSetup()
                                true
                            }
                            "Send interrupt signal" -> {
                                service.signal(sessionId, Signal.INT)
                                true
                            }
                            "Send terminate signal" -> {
                                service.signal(sessionId, Signal.TERM)
                                true
                            }
                            else -> false
                        }
                    }
                    show()
                }
            }
        }
        titleRow.addView(overflow, LinearLayout.LayoutParams(dp(48), -2))
        toolbar.addView(titleRow)
        toolbar.addView(status)
        toolbar.addView(vertical(10).apply {
            setBackgroundColor(surface)
            addView(label("Command tracking needs shell integration.", 13f, primary))
            addView(label("Set it up to identify commands without recording passwords or TUI input.", 12f, secondary))
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                addView(compactButton("Set up") { showShellIntegrationSetup() })
                addView(compactButton("Not now") {
                    service.dismissShellIntegrationNotice(sessionId)
                    shellIntegrationNotice?.visibility = View.GONE
                })
            }.margins(top = 6))
            visibility = View.GONE
        }.also { shellIntegrationNotice = it }.margins(top = 8))
        toolbar.addView(button("Retry / Reauthenticate", secondary) { reauthenticate(sessionId) }.apply {
            visibility = if (service.summaries().firstOrNull { it.sessionId == sessionId }?.canRetry == true) {
                View.VISIBLE
            } else {
                View.GONE
            }
            terminalRetryButton = this
        }.margins(top = 8))
        root.addView(toolbar)

        val view = GhosttyTerminalView(this, terminal, terminalThemeStore.loadFontSize()).apply {
            isEnabled = false
            onInput = { input ->
                val key = input.singleOrNull()?.let { character ->
                    if (character.isLetterOrDigit()) character.uppercase() else "UNIDENTIFIED"
                } ?: "UNIDENTIFIED"
                sessionService?.send(sessionId, terminal.encodeKey(key, input, ghosttyModifierBits(activeModifiers)))
                consumeOneShotModifiers()
            }
            onSpecialKey = { key -> sendBarKey(key, activeModifiers) }
            onKeyEvent = { event -> sendHardwareKey(terminal, event) }
            isMouseTracking = terminal::isMouseTracking
            onMouseEvent = { action, button, x, y, width, height, cellWidth, cellHeight, pressed, metaState ->
                sessionService?.send(sessionId, terminal.encodeMouse(
                    action = action,
                    button = button,
                    x = x,
                    y = y,
                    modifiers = ghosttyModifierBits(activeModifiers) or ghosttyMetaBits(metaState),
                    width = width,
                    height = height,
                    cellWidth = cellWidth,
                    cellHeight = cellHeight,
                    anyPressed = pressed,
                ))
            }
            onTerminalFocusChanged = { focused ->
                terminal.encodeFocus(focused).takeIf(ByteArray::isNotEmpty)?.let { sessionService?.send(sessionId, it) }
            }
            onSelectionStart = terminal::selectWord
            onSelectionUpdate = { start, column, row -> terminal.setSelectionEndpoint(start, column, row) }
            onSelectionFinished = {
                val selected = terminal.selectedText()
                if (selected.isNotEmpty()) {
                    getSystemService(ClipboardManager::class.java).setPrimaryClip(
                        ClipData.newPlainText("Terminal selection", selected),
                    )
                    toast("Selection copied")
                }
            }
            onMetadataChanged = { title, pwd, atPrompt, passwordInput ->
                terminalTitle?.text = title.ifBlank { host.name }
                if (pwd.isNotBlank()) terminalStatus?.text = displayRemotePwd(pwd)
                if (atPrompt) {
                    service.markShellIntegrationDetected(sessionId)
                    shellIntegrationNotice?.visibility = View.GONE
                    cancelShellIntegrationNotice()
                }
                setPasswordInput(passwordInput)
                if (passwordInput) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
            onLinkTap = { column, row ->
                val uri = terminal.hyperlink(column, row).takeIf { it.isNotBlank() }?.let(Uri::parse)
                if (uri?.scheme in setOf("http", "https")) {
                    startActivity(Intent(Intent.ACTION_VIEW, uri))
                    true
                } else {
                    false
                }
            }
            onResize = { columns, rows, pixelWidth, pixelHeight ->
                sessionService?.resize(sessionId, columns, rows, pixelWidth, pixelHeight)
            }
            onScrollPositionChanged = { isAtBottom ->
                terminalAtBottom = isAtBottom
                updateModifierBarVisibility()
            }
            onTextSizeChanged = terminalThemeStore::saveFontSize
        }.also { terminalView = it }
        root.addView(view, LinearLayout.LayoutParams(-1, 0, 1f))
        root.addView(createModifierBar().also { modifierBar = it })
        setContentView(root)
        view.refresh()
        updateModifierBarVisibility()
        service.status(sessionId)?.let { sessionListener.onSessionStatus(sessionId, it) }
    }

    private fun scheduleShellIntegrationNotice(sessionId: String) {
        cancelShellIntegrationNotice()
        val service = sessionService ?: return
        if (service.shellIntegrationDetected(sessionId) || service.shellIntegrationNoticeDismissed(sessionId)) return
        shellIntegrationNoticeRunnable = Runnable {
            if (selectedSessionId == sessionId && service.status(sessionId) == "Connected" &&
                !service.shellIntegrationDetected(sessionId) && !service.shellIntegrationNoticeDismissed(sessionId)
            ) {
                shellIntegrationNotice?.visibility = View.VISIBLE
            }
        }.also { mainHandler.postDelayed(it, SHELL_INTEGRATION_NOTICE_DELAY_MS) }
    }

    private fun cancelShellIntegrationNotice() {
        shellIntegrationNoticeRunnable?.let(mainHandler::removeCallbacks)
        shellIntegrationNoticeRunnable = null
    }

    private fun showShellIntegrationSetup() {
        AlertDialog.Builder(this)
            .setTitle("Set up shell integration")
            .setItems(arrayOf("Bash", "zsh")) { _, index ->
                if (index == 0) {
                    showShellIntegrationInstallCommand(
                        "Bash", R.raw.ghostty_connect_bash, "ghostty-connect.bash", ".bashrc",
                    )
                } else {
                    showShellIntegrationInstallCommand(
                        "zsh", R.raw.ghostty_connect_zsh, "ghostty-connect.zsh", ".zshrc",
                    )
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun showShellIntegrationInstallCommand(
        shell: String,
        scriptResource: Int,
        scriptName: String,
        rcFile: String,
    ) {
        val script = resources.openRawResource(scriptResource).bufferedReader().use { it.readText() }.trimEnd()
        val sourceLine = "source \"\$HOME/.config/ghostty-connect/$scriptName\""
        val installCommand = buildString {
            appendLine("mkdir -p \"\$HOME/.config/ghostty-connect\"")
            appendLine("cat > \"\$HOME/.config/ghostty-connect/$scriptName\" <<'GHOSTTY_CONNECT_EOF'")
            appendLine(script)
            appendLine("GHOSTTY_CONNECT_EOF")
            appendLine("touch \"\$HOME/$rcFile\"")
            appendLine("grep -Fqx '$sourceLine' \"\$HOME/$rcFile\" || printf '%s\\n' '$sourceLine' >> \"\$HOME/$rcFile\"")
            appendLine(sourceLine)
        }.trimEnd()
        AlertDialog.Builder(this)
            .setTitle("$shell setup")
            .setMessage("Copy and paste the installation command into the remote shell. The setup notice will disappear when the next prompt is detected.")
            .setNegativeButton("Back") { _, _ -> showShellIntegrationSetup() }
            .setPositiveButton("Copy command") { _, _ ->
                writeClipboard(installCommand)
                toast("Installation command copied")
            }
            .show()
    }

    private fun createModifierBar(): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setBackgroundColor(raised)
            setPadding(dp(6), dp(4), dp(6), dp(4))
        }.also { modifierBarRow = it }
        renderModifierBarItems()
        return HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            setBackgroundColor(raised)
            addView(row, ViewGroup.LayoutParams(-2, dp(48)))
        }
    }

    private fun renderModifierBarItems() {
        val row = modifierBarRow ?: return
        row.removeAllViews()
        keyboardBarConfig.items.forEach { item -> row.addView(modifierBarButton(item)) }
        row.addView(barButton("More") { showAllKeyboardKeys() })
    }

    private fun modifierBarButton(item: KeyboardBarItem): View {
        val resolved = when (item.type) {
            KeyboardBarItemType.LAST_USED_MODIFIER -> lastUsedModifier?.let { modifier ->
                KeyboardBarCatalog.modifiers.first { modifier in it.modifiers }
            }
            KeyboardBarItemType.LAST_USED_COMBINATION -> lastUsedCombination
            else -> item
        }
        val label = when (item.type) {
            KeyboardBarItemType.LAST_USED_MODIFIER -> lastUsedModifier?.displayName ?: "Last mod"
            KeyboardBarItemType.LAST_USED_COMBINATION -> lastUsedCombination?.label ?: "Last combo"
            else -> item.label
        }
        val modifier = resolved?.modifiers?.singleOrNull().takeIf {
            resolved?.type == KeyboardBarItemType.MODIFIER
        }
        val button = barButton(label, modifier != null && modifier in activeModifiers) {
            resolved?.let(::activateBarItem)
        }
        if (modifier != null) {
            button.setOnLongClickListener {
                lastUsedModifier = modifier
                activeModifiers += modifier
                lockedModifiers += modifier
                renderModifierBarItems()
                true
            }
        }
        return button
    }

    private fun activateBarItem(item: KeyboardBarItem) {
        when (item.type) {
            KeyboardBarItemType.MODIFIER -> {
                val modifier = item.modifiers.single()
                lastUsedModifier = modifier
                if (modifier in activeModifiers) {
                    activeModifiers -= modifier
                    lockedModifiers -= modifier
                } else {
                    activeModifiers += modifier
                }
                renderModifierBarItems()
            }
            KeyboardBarItemType.KEY -> sendBarKey(item.key.orEmpty(), activeModifiers)
            KeyboardBarItemType.COMBINATION -> {
                lastUsedCombination = item
                sendBarKey(item.key.orEmpty(), activeModifiers + item.modifiers)
            }
            KeyboardBarItemType.LAST_USED_MODIFIER -> Unit
            KeyboardBarItemType.LAST_USED_COMBINATION -> lastUsedCombination?.let(::activateBarItem)
        }
    }

    private fun sendBarKey(key: String, modifiers: Set<KeyboardModifier>) {
        val text = key.takeUnless { candidate -> KeyboardBarCatalog.keys.any { it.key == candidate } }.orEmpty()
        val sessionId = selectedSessionId ?: return
        val terminal = sessionService?.terminal(sessionId) ?: return
        sessionService?.send(sessionId, terminal.encodeKey(
            key = key,
            text = text,
            modifiers = ghosttyModifierBits(modifiers),
        ))
        consumeOneShotModifiers()
    }

    private fun sendHardwareKey(terminal: GhosttyTerminal, event: KeyEvent): Boolean {
        val key = androidKeyName(event.keyCode) ?: return false
        val codepoint = event.unicodeChar
        val text = codepoint.takeIf { it > 31 && it != 127 }?.let { String(Character.toChars(it)) }.orEmpty()
        val action = when {
            event.action == KeyEvent.ACTION_UP -> GhosttyTerminal.KEY_ACTION_RELEASE
            event.repeatCount > 0 -> GhosttyTerminal.KEY_ACTION_REPEAT
            else -> GhosttyTerminal.KEY_ACTION_PRESS
        }
        val modifiers = ghosttyModifierBits(activeModifiers) or
            (if (event.isShiftPressed) GHOSTTY_MOD_SHIFT else 0) or
            (if (event.isCtrlPressed) GHOSTTY_MOD_CTRL else 0) or
            (if (event.isAltPressed) GHOSTTY_MOD_ALT else 0) or
            (if (event.isMetaPressed) GHOSTTY_MOD_SUPER else 0) or
            (if (event.isCapsLockOn) GHOSTTY_MOD_CAPS_LOCK else 0) or
            (if (event.isNumLockOn) GHOSTTY_MOD_NUM_LOCK else 0)
        selectedSessionId?.let { sessionService?.send(it, terminal.encodeKey(key, text, modifiers, action)) }
        if (action == GhosttyTerminal.KEY_ACTION_PRESS && !KeyEvent.isModifierKey(event.keyCode)) {
            consumeOneShotModifiers()
        }
        return true
    }

    private fun androidKeyName(keyCode: Int): String? = when (keyCode) {
        in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z -> ('A'.code + keyCode - KeyEvent.KEYCODE_A).toChar().toString()
        in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9 -> (keyCode - KeyEvent.KEYCODE_0).toString()
        KeyEvent.KEYCODE_ESCAPE -> "ESCAPE"
        KeyEvent.KEYCODE_TAB -> "TAB"
        KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> "ENTER"
        KeyEvent.KEYCODE_DEL -> "BACKSPACE"
        KeyEvent.KEYCODE_FORWARD_DEL -> "DELETE"
        KeyEvent.KEYCODE_INSERT -> "INSERT"
        KeyEvent.KEYCODE_MOVE_HOME -> "HOME"
        KeyEvent.KEYCODE_MOVE_END -> "END"
        KeyEvent.KEYCODE_PAGE_UP -> "PAGE_UP"
        KeyEvent.KEYCODE_PAGE_DOWN -> "PAGE_DOWN"
        KeyEvent.KEYCODE_DPAD_UP -> "ARROW_UP"
        KeyEvent.KEYCODE_DPAD_DOWN -> "ARROW_DOWN"
        KeyEvent.KEYCODE_DPAD_LEFT -> "ARROW_LEFT"
        KeyEvent.KEYCODE_DPAD_RIGHT -> "ARROW_RIGHT"
        in KeyEvent.KEYCODE_F1..KeyEvent.KEYCODE_F12 -> "F${keyCode - KeyEvent.KEYCODE_F1 + 1}"
        KeyEvent.KEYCODE_SPACE -> "SPACE"
        KeyEvent.KEYCODE_GRAVE -> "BACKQUOTE"
        KeyEvent.KEYCODE_BACKSLASH -> "BACKSLASH"
        KeyEvent.KEYCODE_LEFT_BRACKET -> "BRACKET_LEFT"
        KeyEvent.KEYCODE_RIGHT_BRACKET -> "BRACKET_RIGHT"
        KeyEvent.KEYCODE_COMMA -> "COMMA"
        KeyEvent.KEYCODE_EQUALS -> "EQUAL"
        KeyEvent.KEYCODE_MINUS -> "MINUS"
        KeyEvent.KEYCODE_PERIOD -> "PERIOD"
        KeyEvent.KEYCODE_APOSTROPHE -> "QUOTE"
        KeyEvent.KEYCODE_SEMICOLON -> "SEMICOLON"
        KeyEvent.KEYCODE_SLASH -> "SLASH"
        KeyEvent.KEYCODE_SHIFT_LEFT -> "SHIFT_LEFT"
        KeyEvent.KEYCODE_SHIFT_RIGHT -> "SHIFT_RIGHT"
        KeyEvent.KEYCODE_CTRL_LEFT -> "CONTROL_LEFT"
        KeyEvent.KEYCODE_CTRL_RIGHT -> "CONTROL_RIGHT"
        KeyEvent.KEYCODE_ALT_LEFT -> "ALT_LEFT"
        KeyEvent.KEYCODE_ALT_RIGHT -> "ALT_RIGHT"
        KeyEvent.KEYCODE_META_LEFT -> "META_LEFT"
        KeyEvent.KEYCODE_META_RIGHT -> "META_RIGHT"
        else -> null
    }

    private fun ghosttyModifierBits(modifiers: Set<KeyboardModifier>): Int =
        (if (KeyboardModifier.SHIFT in modifiers) GHOSTTY_MOD_SHIFT else 0) or
            (if (KeyboardModifier.CONTROL in modifiers) GHOSTTY_MOD_CTRL else 0) or
            (if (KeyboardModifier.ALT in modifiers) GHOSTTY_MOD_ALT else 0) or
            (if (KeyboardModifier.META in modifiers) GHOSTTY_MOD_SUPER else 0) or
            (if (KeyboardModifier.CAPS_LOCK in modifiers) GHOSTTY_MOD_CAPS_LOCK else 0) or
            (if (KeyboardModifier.NUM_LOCK in modifiers) GHOSTTY_MOD_NUM_LOCK else 0)

    private fun ghosttyMetaBits(metaState: Int): Int =
        (if (metaState and KeyEvent.META_SHIFT_ON != 0) GHOSTTY_MOD_SHIFT else 0) or
            (if (metaState and KeyEvent.META_CTRL_ON != 0) GHOSTTY_MOD_CTRL else 0) or
            (if (metaState and KeyEvent.META_ALT_ON != 0) GHOSTTY_MOD_ALT else 0) or
            (if (metaState and KeyEvent.META_META_ON != 0) GHOSTTY_MOD_SUPER else 0) or
            (if (metaState and KeyEvent.META_CAPS_LOCK_ON != 0) GHOSTTY_MOD_CAPS_LOCK else 0) or
            (if (metaState and KeyEvent.META_NUM_LOCK_ON != 0) GHOSTTY_MOD_NUM_LOCK else 0)

    private fun pasteFromClipboard(service: SshSessionService) {
        val text = getSystemService(ClipboardManager::class.java).primaryClip
            ?.getItemAt(0)?.coerceToText(this)?.toString().orEmpty()
        if (text.isEmpty()) {
            toast("Clipboard is empty.")
            return
        }
        val sessionId = selectedSessionId ?: return
        val terminal = service.terminal(sessionId) ?: return
        val paste = { service.send(sessionId, terminal.encodePaste(text)) }
        if (terminal.isPasteSafe(text)) {
            paste()
        } else {
            AlertDialog.Builder(this)
                .setTitle("Paste multiple lines?")
                .setMessage("This paste contains a newline or terminal control sequence.")
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Paste") { _, _ -> paste() }
                .show()
        }
    }

    private fun handleRemoteClipboard(text: String) {
        val host = currentStoredHost() ?: return
        when (host.allowRemoteClipboard) {
            true -> writeClipboard(text)
            false -> Unit
            null -> AlertDialog.Builder(this)
                .setTitle("Allow remote clipboard writes?")
                .setMessage("${host.name} requested permission to replace the Android clipboard.")
                .setNegativeButton("Block") { _, _ -> hostStore.save(host.copy(allowRemoteClipboard = false)) }
                .setPositiveButton("Allow") { _, _ ->
                    hostStore.save(host.copy(allowRemoteClipboard = true))
                    writeClipboard(text)
                }
                .show()
        }
    }

    private fun writeClipboard(text: String) {
        getSystemService(ClipboardManager::class.java).setPrimaryClip(
            ClipData.newPlainText("Remote terminal", text),
        )
    }

    private fun handleRemoteNotification(title: String, body: String) {
        val host = currentStoredHost() ?: return
        when (host.allowRemoteNotifications) {
            true -> showRemoteNotification(host, title, body)
            false -> Unit
            null -> AlertDialog.Builder(this)
                .setTitle("Allow terminal notifications?")
                .setMessage("${host.name} requested permission to create Android notifications.")
                .setNegativeButton("Block") { _, _ -> hostStore.save(host.copy(allowRemoteNotifications = false)) }
                .setPositiveButton("Allow") { _, _ ->
                    hostStore.save(host.copy(allowRemoteNotifications = true))
                    showRemoteNotification(host, title, body)
                }
                .show()
        }
    }

    private fun showRemoteNotification(host: Host, title: String, body: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(REMOTE_NOTIFICATION_CHANNEL, "Remote terminal notifications", NotificationManager.IMPORTANCE_DEFAULT),
        )
        val open = PendingIntent.getActivity(
            this,
            selectedSessionId?.hashCode() ?: 0,
            Intent(this, MainActivity::class.java)
                .setAction(SshSessionService.ACTION_OPEN_SESSION)
                .setData(Uri.parse("ghostty-connect://session/${selectedSessionId.orEmpty()}/open"))
                .putExtra(SshSessionService.EXTRA_SESSION_ID, selectedSessionId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        manager.notify(
            (System.currentTimeMillis() and 0x7fffffff).toInt(),
            android.app.Notification.Builder(this, REMOTE_NOTIFICATION_CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle(title.ifBlank { host.name })
                .setContentText(body)
                .setStyle(android.app.Notification.BigTextStyle().bigText(body))
                .setContentIntent(open)
                .setAutoCancel(true)
                .build(),
        )
    }

    private fun currentStoredHost(): Host? {
        val sessionId = selectedSessionId ?: return null
        val id = sessionService?.host(sessionId)?.id ?: return null
        return hostStore.loadAll().firstOrNull { it.id == id }
    }

    private fun consumeOneShotModifiers() {
        activeModifiers.retainAll(lockedModifiers)
        renderModifierBarItems()
    }

    private fun updateModifierBarVisibility() {
        modifierBar?.visibility = if (keyboardBarConfig.enabled && imeVisible && terminalAtBottom) {
            View.VISIBLE
        } else {
            View.GONE
        }
    }

    private fun showAllKeyboardKeys() {
        val items = KeyboardBarCatalog.availableItems.filter {
            it.type != KeyboardBarItemType.LAST_USED_MODIFIER &&
                it.type != KeyboardBarItemType.LAST_USED_COMBINATION
        } + keyboardBarConfig.combinations
        AlertDialog.Builder(this)
            .setTitle("Keyboard keys")
            .setItems(items.map(KeyboardBarItem::label).toTypedArray()) { _, index -> activateBarItem(items[index]) }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun setTerminalEnabled(enabled: Boolean) {
        terminalView?.isEnabled = enabled
        if (enabled) terminalView?.requestFocus()
    }

    private fun displayRemotePwd(value: String): String = runCatching {
        val uri = Uri.parse(value)
        if (uri.scheme == "file") uri.path.orEmpty().ifBlank { value } else value
    }.getOrDefault(value)

    private fun showScrollbackSearch(terminal: GhosttyTerminal) {
        val query = field("Search scrollback", terminalSearchQuery)
        val dialog = AlertDialog.Builder(this)
            .setTitle("Search scrollback")
            .setView(query)
            .setNegativeButton("Cancel", null)
            .setNeutralButton("Previous", null)
            .setPositiveButton("Next", null)
            .create()
        dialog.setOnShowListener {
            fun search(direction: Int) {
                if (query.text.isBlank()) return
                terminalSearchQuery = query.text.toString()
                if (!terminal.search(terminalSearchQuery, direction)) toast("No match")
                terminalView?.refresh()
            }
            dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener { search(-1) }
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener { search(1) }
        }
        dialog.show()
        dialog.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE)
        query.requestFocus()
    }

    private fun handleBackNavigation() {
        if (settingsVisible) showHosts(disconnect = false)
        else if (terminalView != null || previewTerminal != null) showHosts()
        else finish()
    }

    @SuppressLint("GestureBackNavigation")
    @Deprecated("Fallback for Android 10 through 12")
    override fun onBackPressed() = handleBackNavigation()

    override fun onDestroy() {
        cancelShellIntegrationNotice()
        pendingConnection?.credential?.fill('\u0000')
        pendingConnection = null
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
    private fun compactButton(text: String, enabled: Boolean = true, action: () -> Unit) = Button(this).apply {
        this.text = text; isEnabled = enabled; isAllCaps = false; setTextColor(primary); setBackgroundColor(surface)
        minWidth = 0; minimumWidth = 0; setPadding(dp(8), 0, dp(8), 0); setOnClickListener { action() }
    }
    private fun barButton(text: String, active: Boolean = false, action: () -> Unit) = Button(this).apply {
        this.text = text; isAllCaps = false; setTextColor(if (active) Color.rgb(8, 15, 12) else primary)
        setBackgroundColor(if (active) accent else surface); minWidth = dp(52); minimumWidth = dp(52)
        setPadding(dp(10), 0, dp(10), 0); setOnClickListener { action() }
    }
    private fun View.margins(top: Int = 0, bottom: Int = 0): View = apply {
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(top); bottomMargin = dp(bottom) }
    }
    private fun toast(message: String) = Toast.makeText(this, message, Toast.LENGTH_LONG).show()
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    companion object {
        const val IMPORT_KEY = 1001
        const val NOTIFICATION_PERMISSION = 1002
        const val GHOSTTY_MOD_SHIFT = 1 shl 0
        const val GHOSTTY_MOD_CTRL = 1 shl 1
        const val GHOSTTY_MOD_ALT = 1 shl 2
        const val GHOSTTY_MOD_SUPER = 1 shl 3
        const val GHOSTTY_MOD_CAPS_LOCK = 1 shl 4
        const val GHOSTTY_MOD_NUM_LOCK = 1 shl 5
        const val REMOTE_NOTIFICATION_CHANNEL = "remote_terminal"
        private const val SHELL_INTEGRATION_NOTICE_DELAY_MS = 15_000L
    }
}
