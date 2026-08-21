package dev.ghostty.connect.terminal

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Binder
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import dev.ghostty.connect.MainActivity
import dev.ghostty.connect.data.HostStore
import dev.ghostty.connect.data.SshKeyStore
import dev.ghostty.connect.data.TerminalStateStore
import dev.ghostty.connect.data.TerminalThemeStore
import dev.ghostty.connect.model.AuthenticationType
import dev.ghostty.connect.model.Host
import dev.ghostty.connect.terminal.bridge.GhosttyTerminal
import dev.ghostty.connect.terminal.bridge.TerminalEffects
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import net.schmizz.sshj.connection.channel.direct.Signal

class SshSessionService : Service() {
    interface Listener {
        fun onSessionStatus(sessionId: String, status: String)
        fun onTerminalChanged(sessionId: String)
        fun onTerminalEffects(sessionId: String, effects: TerminalEffects)
        fun onHostKeyVerification(
            sessionId: String,
            fingerprint: String,
            changed: Boolean,
            answer: (Boolean) -> Unit,
        )
        fun onAuthenticationChallenge(
            sessionId: String,
            hostName: String,
            challenge: AuthenticationChallenge,
            answer: (CharArray?) -> Unit,
        )
        fun onSessionClosed(sessionId: String, error: String?)
    }

    inner class LocalBinder : Binder() {
        val service: SshSessionService get() = this@SshSessionService
    }

    private data class PendingVerification(
        val fingerprint: String,
        val changed: Boolean,
        val answer: (Boolean) -> Unit,
    )

    private data class PendingChallenge(
        val generation: Long,
        val challenge: AuthenticationChallenge,
        val answer: (CharArray?) -> Unit,
    )

    private inner class SessionRecord(
        val sessionId: String,
        val host: Host,
        val terminal: GhosttyTerminal,
        val autoReconnectEligible: Boolean,
    ) {
        val outputLock = Any()
        val pendingEffects = ArrayDeque<TerminalEffects>()
        val framePending = AtomicBoolean(false)
        val cleaningUp = AtomicBoolean(false)
        val reconnectPolicy = ReconnectPolicy()
        var connection: SshConnection? = null
        var itermImageParser: ItermInlineImageParser? = null
        var tmuxPassthroughParser: TmuxPassthroughParser? = null
        var terminalMetrics = TerminalPixelMetrics(80, 24, 640, 384)
        var pendingVerification: PendingVerification? = null
        var pendingChallenge: PendingChallenge? = null
        var retryRunnable: Runnable? = null
        var stableConnectionRunnable: Runnable? = null
        var waitingToReconnect = false
        var manualRetryAvailable = false
        var connected = false
        var shellEstablished = false
        var shellIntegrationDetected = false
        var shellIntegrationNoticeDismissed = false
        @Volatile var attemptGeneration = 0L
        var status = "Connecting…"
    }

    private inner class AttemptCallbacks(
        private val record: SessionRecord,
        private val generation: Long,
    ) : SshConnection.Callbacks {
        override fun status(message: String) = onMain {
            if (!isCurrentAttempt(record, generation)) return@onMain
            setStatus(record, message)
        }

        override fun output(bytes: ByteArray) {
            val visibleEffects = synchronized(record.outputLock) {
                if (record.cleaningUp.get() || record.attemptGeneration != generation) return
                record.tmuxPassthroughParser?.feed(bytes) ?: record.terminal.write(bytes)
                val effects = record.terminal.drainEffects()
                if (effects.ptyWrite.isNotEmpty() && record.connected) record.connection?.send(effects.ptyWrite)
                if (effects.ptyWrite.isNotEmpty()) effects.copy(ptyWrite = byteArrayOf()) else effects
            }
            onMain {
                if (!isCurrentAttempt(record, generation)) return@onMain
                if (!visibleEffects.isEmpty) {
                    if (listener != null && listenerSessionId == record.sessionId) {
                        listener?.onTerminalEffects(record.sessionId, visibleEffects)
                    } else {
                        handleBackgroundEffects(record, visibleEffects)
                    }
                }
                scheduleTerminalChanged(record)
            }
        }

        override fun verifyHostKey(fingerprint: String, changed: Boolean, answer: (Boolean) -> Unit) {
            val answered = AtomicBoolean(false)
            val once: (Boolean) -> Unit = { accepted ->
                if (answered.compareAndSet(false, true)) {
                    onMain {
                        if (isCurrentAttempt(record, generation)) record.pendingVerification = null
                        answer(accepted && isCurrentAttempt(record, generation))
                    }
                }
            }
            onMain {
                if (!isCurrentAttempt(record, generation)) {
                    once(false)
                    return@onMain
                }
                record.pendingVerification = PendingVerification(fingerprint, changed, once)
                listener?.onHostKeyVerification(record.sessionId, fingerprint, changed, once)
            }
        }

        override fun challenge(
            challenge: AuthenticationChallenge,
            answer: (CharArray?) -> Unit,
        ): () -> Unit {
            lateinit var respond: (CharArray?) -> Unit
            val once = ExactlyOnceAnswer<CharArray> { submitted ->
                onMain {
                    val current = isCurrentAttempt(record, generation) &&
                        record.pendingChallenge?.let { it.generation == generation && it.answer === respond } == true
                    if (current) record.pendingChallenge = null
                    val owned = submitted?.copyOf()
                    submitted?.fill('\u0000')
                    if (current) {
                        answer(owned)
                    } else {
                        owned?.fill('\u0000')
                        answer(null)
                    }
                }
            }
            respond = { submitted ->
                if (!once.answer(submitted)) submitted?.fill('\u0000')
            }
            onMain {
                if (!isCurrentAttempt(record, generation) || once.isAnswered) {
                    respond(null)
                    return@onMain
                }
                record.pendingChallenge?.answer?.invoke(null)
                record.pendingChallenge = PendingChallenge(generation, challenge, respond)
                listener?.onAuthenticationChallenge(record.sessionId, record.host.name, challenge, respond)
            }
            return { respond(null) }
        }

        override fun connected() = onMain {
            if (!isCurrentAttempt(record, generation)) return@onMain
            record.connected = true
            record.waitingToReconnect = false
            record.retryRunnable = null
            record.stableConnectionRunnable?.let(mainHandler::removeCallbacks)
            record.stableConnectionRunnable = Runnable {
                record.stableConnectionRunnable = null
                if (isCurrentAttempt(record, generation) && record.connected) record.reconnectPolicy.reset()
            }.also { mainHandler.postDelayed(it, STABLE_CONNECTION_MS) }
            if (record.shellEstablished) {
                appendTerminalMessage(
                    record,
                    "New SSH shell established. This is a new shell; use tmux or screen for remote process continuity.",
                )
            }
            record.shellEstablished = true
            setStatus(record, STATUS_CONNECTED)
        }

        override fun closed(closure: SshClosure) = onMain {
            if (!isCurrentAttempt(record, generation)) return@onMain
            record.stableConnectionRunnable?.let(mainHandler::removeCallbacks)
            record.stableConnectionRunnable = null
            record.connection = null
            record.connected = false
            handleClosure(record, closure)
        }
    }

    private val binder = LocalBinder()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val sessions = LinkedHashMap<String, SessionRecord>()
    private var listener: Listener? = null
    private var listenerSessionId: String? = null
    private var notificationSessionId: String? = null
    private val connectivityManager by lazy { getSystemService(ConnectivityManager::class.java) }
    private var networkCallbackRegistered = false
    private var networkUsable = false
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = refreshNetworkState()
        override fun onLost(network: Network) = refreshNetworkState()
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = refreshNetworkState()
    }

    override fun onCreate() {
        super.onCreate()
        active = true
        createNotificationChannel()
        startInForeground(null)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_DISCONNECT) {
            intent.getStringExtra(EXTRA_SESSION_ID)?.let { sessionId -> onMain { disconnect(sessionId) } }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder = binder

    fun attach(listener: Listener, selectedSessionId: String?) = onServiceMain {
        this.listener = listener
        selectListenerSession(selectedSessionId)
        sessions.values.forEach { record ->
            listener.onSessionStatus(record.sessionId, record.status)
            listener.onTerminalChanged(record.sessionId)
            record.pendingVerification?.let {
                listener.onHostKeyVerification(record.sessionId, it.fingerprint, it.changed, it.answer)
            }
            record.pendingChallenge?.let {
                listener.onAuthenticationChallenge(record.sessionId, record.host.name, it.challenge, it.answer)
            }
        }
    }

    fun detach(listener: Listener) = onServiceMain {
        if (this.listener === listener) {
            this.listener = null
            listenerSessionId = null
        }
    }

    fun selectListenerSession(sessionId: String?) = onServiceMain {
        listenerSessionId = sessionId?.takeIf(sessions::containsKey)
        val record = listenerSessionId?.let(sessions::get) ?: return@onServiceMain
        listener?.onSessionStatus(record.sessionId, record.status)
        listener?.onTerminalChanged(record.sessionId)
        while (record.pendingEffects.isNotEmpty()) {
            listener?.onTerminalEffects(record.sessionId, record.pendingEffects.removeFirst())
        }
    }

    fun connect(sessionId: String, host: Host, credential: CharArray) = onServiceMain {
        if (sessionId.isBlank() || sessionId in sessions) {
            credential.fill('\u0000')
            require(sessionId.isNotBlank()) { "sessionId must not be blank" }
            error("Session already exists: $sessionId")
        }
        val theme = TerminalThemeStore(applicationContext).load()
        val terminal = GhosttyTerminal(
            foreground = theme.foreground,
            background = theme.background,
            cursor = theme.cursor,
            palette = theme.palette,
        )
        val keyStore = SshKeyStore(applicationContext)
        val autoReconnectEligible = host.authenticationType == AuthenticationType.SSH_KEY &&
            host.identityId?.let { runCatching { !keyStore.requiresPassphrase(it) }.getOrDefault(false) } == true
        val record = SessionRecord(sessionId, host, terminal, autoReconnectEligible)
        resetParsers(record)
        sessions[sessionId] = record
        ensureNetworkCallback()
        listenerSessionId = sessionId
        notificationSessionId = sessionId
        startInForeground(record)
        listener?.onSessionStatus(sessionId, record.status)
        listener?.onTerminalChanged(sessionId)
        startAttempt(record, credential)
    }

    fun summaries(): List<SessionSummary> = onServiceMainResult {
        sessions.values.map { sessionSummary(it.sessionId, it.host, it.status, it.manualRetryAvailable) }
    }

    fun host(sessionId: String): Host? = onServiceMainResult { sessions[sessionId]?.host }

    fun terminal(sessionId: String): GhosttyTerminal? = onServiceMainResult { sessions[sessionId]?.terminal }

    fun status(sessionId: String): String? = onServiceMainResult { sessions[sessionId]?.status }

    fun shellIntegrationDetected(sessionId: String): Boolean = onServiceMainResult {
        sessions[sessionId]?.shellIntegrationDetected == true
    }

    fun markShellIntegrationDetected(sessionId: String) = onServiceMain {
        sessions[sessionId]?.shellIntegrationDetected = true
    }

    fun shellIntegrationNoticeDismissed(sessionId: String): Boolean = onServiceMainResult {
        sessions[sessionId]?.shellIntegrationNoticeDismissed == true
    }

    fun dismissShellIntegrationNotice(sessionId: String) = onServiceMain {
        sessions[sessionId]?.shellIntegrationNoticeDismissed = true
    }

    fun send(sessionId: String, text: String) = onServiceMain {
        sessions[sessionId]?.takeIf { it.connected }?.connection?.send(text)
    }

    fun send(sessionId: String, bytes: ByteArray) = onServiceMain {
        sessions[sessionId]?.takeIf { it.connected }?.connection?.send(bytes)
    }

    fun signal(sessionId: String, signal: Signal) = onServiceMain {
        sessions[sessionId]?.takeIf { it.connected }?.connection?.signal(signal)
    }

    fun resize(sessionId: String, columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) = onServiceMain {
        sessions[sessionId]?.let {
            it.terminalMetrics = TerminalPixelMetrics(columns, rows, pixelWidth, pixelHeight)
            if (it.connected) it.connection?.resize(columns, rows, pixelWidth, pixelHeight)
        }
    }

    fun retry(sessionId: String, credential: CharArray) = onServiceMain {
        val record = sessions[sessionId] ?: run {
            credential.fill('\u0000')
            return@onServiceMain
        }
        cancelAttempt(record)
        record.reconnectPolicy.reset()
        record.waitingToReconnect = false
        record.manualRetryAvailable = false
        resetParsers(record)
        setStatus(record, "Connecting…")
        startAttempt(record, credential)
    }

    fun disconnect(sessionId: String) = onServiceMain {
        val record = sessions[sessionId] ?: return@onServiceMain
        record.pendingVerification?.answer?.invoke(false)
        record.pendingVerification = null
        listener?.onSessionClosed(sessionId, null)
        removeSession(record)
    }

    override fun onDestroy() {
        check(Looper.myLooper() == Looper.getMainLooper())
        sessions.values.toList().forEach(::cleanup)
        sessions.clear()
        unregisterNetworkCallback()
        active = false
        super.onDestroy()
    }

    private fun removeSession(record: SessionRecord) {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (!isCurrent(record)) return
        sessions.remove(record.sessionId)
        cleanup(record)
        if (listenerSessionId == record.sessionId) listenerSessionId = null
        if (sessions.isEmpty()) {
            unregisterNetworkCallback()
            notificationSessionId = null
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        } else if (notificationSessionId == record.sessionId) {
            sessions.values.first().let {
                notificationSessionId = it.sessionId
                startInForeground(it)
            }
        }
    }

    private fun startAttempt(record: SessionRecord, credential: CharArray) {
        if (!isCurrent(record) || record.cleaningUp.get()) {
            credential.fill('\u0000')
            return
        }
        record.retryRunnable?.let(mainHandler::removeCallbacks)
        record.retryRunnable = null
        record.waitingToReconnect = false
        record.manualRetryAvailable = false
        record.connected = false
        val generation = ++record.attemptGeneration
        val connection = SshConnection(
            applicationContext,
            SshKeyStore(applicationContext),
            AttemptCallbacks(record, generation),
        )
        record.connection = connection
        record.terminalMetrics.let {
            connection.resize(it.columns, it.rows, it.pixelWidth, it.pixelHeight)
        }
        connection.connect(record.host, credential)
    }

    private fun cancelAttempt(record: SessionRecord) {
        record.retryRunnable?.let(mainHandler::removeCallbacks)
        record.retryRunnable = null
        record.stableConnectionRunnable?.let(mainHandler::removeCallbacks)
        record.stableConnectionRunnable = null
        record.waitingToReconnect = false
        record.pendingChallenge?.answer?.invoke(null)
        record.pendingChallenge = null
        record.attemptGeneration++
        record.connected = false
        record.connection?.disconnect()
        record.connection = null
    }

    private fun handleClosure(record: SessionRecord, closure: SshClosure) {
        when (closure.kind) {
            SshClosureKind.NORMAL -> {
                if (!networkUsable) {
                    handleClosure(record, SshClosure(SshClosureKind.RETRYABLE, "Network connection lost"))
                } else {
                    listener?.onSessionClosed(record.sessionId, null)
                    removeSession(record)
                }
            }
            SshClosureKind.PERMANENT -> {
                val message = closure.message ?: "SSH connection failed"
                appendTerminalMessage(record, "Connection failed: $message")
                listener?.onSessionClosed(record.sessionId, message)
                removeSession(record)
            }
            SshClosureKind.RETRYABLE -> {
                appendTerminalMessage(record, "Connection lost. Terminal input is paused while the connection is restored.")
                if (record.autoReconnectEligible) {
                    scheduleReconnect(record)
                } else {
                    record.manualRetryAvailable = true
                    appendTerminalMessage(record, "Re-authentication is required to start a new SSH shell.")
                    setStatus(record, STATUS_REAUTHENTICATION_REQUIRED)
                    listener?.onSessionClosed(record.sessionId, closure.message)
                }
            }
        }
    }

    private fun scheduleReconnect(record: SessionRecord) {
        if (!isCurrent(record) || record.cleaningUp.get()) return
        if (!networkUsable) {
            record.waitingToReconnect = true
            setStatus(record, STATUS_WAITING_FOR_NETWORK)
            return
        }
        val now = android.os.SystemClock.elapsedRealtime()
        val delay = record.reconnectPolicy.nextDelay(now)
        if (delay == null) {
            val message = "Automatic reconnect stopped after 5 attempts."
            appendTerminalMessage(record, message)
            listener?.onSessionClosed(record.sessionId, message)
            removeSession(record)
            return
        }
        record.waitingToReconnect = true
        setStatus(record, if (delay == 0L) "Reconnecting…" else "Reconnecting in ${delay / 1_000}s")
        val retry = Runnable {
            record.retryRunnable = null
            if (!isCurrent(record) || record.cleaningUp.get()) return@Runnable
            if (!networkUsable) {
                scheduleReconnect(record)
                return@Runnable
            }
            val attemptTime = android.os.SystemClock.elapsedRealtime()
            if (!record.reconnectPolicy.beginAttempt(attemptTime)) {
                scheduleReconnect(record)
                return@Runnable
            }
            resetParsers(record)
            startAttempt(record, CharArray(0))
        }
        record.retryRunnable = retry
        mainHandler.postDelayed(retry, delay)
    }

    private fun resetParsers(record: SessionRecord) = synchronized(record.outputLock) {
        record.itermImageParser?.reset()
        record.tmuxPassthroughParser?.reset()
        record.itermImageParser = ItermInlineImageParser(
            onBytes = record.terminal::write,
            onImage = { image ->
                runCatching { ItermImageTranslator.translate(image, record.terminalMetrics) }
                    .getOrDefault(emptyList())
                    .forEach(record.terminal::write)
            },
        )
        record.tmuxPassthroughParser = TmuxPassthroughParser(record.itermImageParser!!::feed)
    }

    private fun appendTerminalMessage(record: SessionRecord, message: String) {
        synchronized(record.outputLock) {
            if (!record.cleaningUp.get()) record.terminal.write("\r\n\r\n\u001b[33m--- $message ---\u001b[0m\r\n")
        }
        listener?.onTerminalChanged(record.sessionId)
    }

    private fun setStatus(record: SessionRecord, status: String) {
        if (!isCurrent(record)) return
        record.status = status
        if (notificationSessionId == record.sessionId) updateNotification(record)
        listener?.onSessionStatus(record.sessionId, status)
    }

    private fun ensureNetworkCallback() {
        if (networkCallbackRegistered) return
        networkUsable = currentNetworkUsable()
        runCatching { connectivityManager.registerDefaultNetworkCallback(networkCallback) }
            .onSuccess { networkCallbackRegistered = true }
    }

    private fun unregisterNetworkCallback() {
        if (!networkCallbackRegistered) return
        runCatching { connectivityManager.unregisterNetworkCallback(networkCallback) }
        networkCallbackRegistered = false
        networkUsable = false
    }

    private fun refreshNetworkState() = onMain {
        val usable = currentNetworkUsable()
        if (networkUsable == usable) return@onMain
        networkUsable = usable
        if (usable) {
            sessions.values.filter { it.waitingToReconnect && it.connection == null }.forEach(::scheduleReconnect)
        } else {
            sessions.values.filter { it.waitingToReconnect }.forEach { record ->
                record.retryRunnable?.let(mainHandler::removeCallbacks)
                record.retryRunnable = null
                setStatus(record, STATUS_WAITING_FOR_NETWORK)
            }
        }
    }

    private fun currentNetworkUsable(): Boolean {
        val network = connectivityManager.activeNetwork ?: return false
        val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return false
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_SUSPENDED)
    }

    private fun cleanup(record: SessionRecord) {
        if (!record.cleaningUp.compareAndSet(false, true)) return
        cancelAttempt(record)
        synchronized(record.outputLock) {
            record.pendingVerification?.answer?.invoke(false)
            record.pendingVerification = null
            record.pendingChallenge?.answer?.invoke(null)
            record.pendingChallenge = null
            record.itermImageParser?.reset()
            record.itermImageParser = null
            record.tmuxPassthroughParser?.reset()
            record.tmuxPassthroughParser = null
            runCatching {
                TerminalStateStore(applicationContext).save(record.host.id, record.terminal.encodeState())
            }
            record.terminal.close()
        }
    }

    private fun isCurrent(record: SessionRecord): Boolean = sessions[record.sessionId] === record

    private fun isCurrentAttempt(record: SessionRecord, generation: Long): Boolean =
        isCurrent(record) && record.attemptGeneration == generation && !record.cleaningUp.get()

    private fun scheduleTerminalChanged(record: SessionRecord) {
        if (!record.framePending.compareAndSet(false, true)) return
        mainHandler.postDelayed({
            record.framePending.set(false)
            if (isCurrent(record)) listener?.onTerminalChanged(record.sessionId)
        }, FRAME_INTERVAL_MS)
    }

    private fun handleBackgroundEffects(record: SessionRecord, effects: TerminalEffects) {
        val storedHost = HostStore(applicationContext, SshKeyStore(applicationContext))
            .loadAll().firstOrNull { it.id == record.host.id }
        if (effects.progressState >= 0 && effects.progress >= 0 && notificationSessionId == record.sessionId) {
            updateNotification(record, "${effects.progress}%")
        }
        var queued = effects.copy(bells = 0, progressState = -1, progress = -1)
        if (effects.clipboard.isNotEmpty()) {
            when (storedHost?.allowRemoteClipboard) {
                true -> getSystemService(ClipboardManager::class.java).setPrimaryClip(
                    ClipData.newPlainText("Remote terminal", effects.clipboard),
                )
                false -> Unit
                null -> queueEffects(record, queued.copy(notificationTitle = "", notificationBody = ""))
            }
            queued = queued.copy(clipboard = "")
        }
        if (effects.notificationTitle.isNotEmpty() || effects.notificationBody.isNotEmpty()) {
            when (storedHost?.allowRemoteNotifications) {
                true -> showRemoteNotification(record, effects.notificationTitle, effects.notificationBody)
                false -> Unit
                null -> queueEffects(record, queued.copy(clipboard = ""))
            }
        }
    }

    private fun queueEffects(record: SessionRecord, effects: TerminalEffects) {
        if (effects.isEmpty) return
        if (record.pendingEffects.size >= 8) record.pendingEffects.removeFirst()
        record.pendingEffects.addLast(effects)
    }

    private fun showRemoteNotification(record: SessionRecord, title: String, body: String) {
        getSystemService(NotificationManager::class.java).notify(
            (System.currentTimeMillis() and 0x7fffffff).toInt(),
            Notification.Builder(this, REMOTE_CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle(title.ifBlank { record.host.name })
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setContentIntent(openIntent(record.sessionId))
                .setAutoCancel(true)
                .build(),
        )
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "SSH sessions", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shows an active background SSH connection"
                setShowBadge(false)
            },
        )
        manager.createNotificationChannel(
            NotificationChannel(REMOTE_CHANNEL_ID, "Remote terminal notifications", NotificationManager.IMPORTANCE_DEFAULT),
        )
    }

    private fun startInForeground(record: SessionRecord?) {
        startForeground(NOTIFICATION_ID, notification(record), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
    }

    private fun updateNotification(record: SessionRecord, message: String = record.status) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(record, message))
    }

    private fun notification(record: SessionRecord?, message: String = record?.status ?: "Preparing connection…"): Notification {
        val sessionId = record?.sessionId
        val builder = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle(record?.host?.let { "Connected to ${it.name}" } ?: "Ghostty Connect")
            .setContentText(message)
            .setContentIntent(sessionId?.let(::openIntent))
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
        if (sessionId != null) {
            builder.addAction(Notification.Action.Builder(null, "Disconnect", disconnectIntent(sessionId)).build())
        }
        return builder.build()
    }

    private fun openIntent(sessionId: String): PendingIntent = PendingIntent.getActivity(
        this,
        sessionId.hashCode(),
        Intent(this, MainActivity::class.java)
            .setAction(ACTION_OPEN_SESSION)
            .setData(Uri.parse("ghostty-connect://session/$sessionId/open"))
            .putExtra(EXTRA_SESSION_ID, sessionId),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun disconnectIntent(sessionId: String): PendingIntent = PendingIntent.getService(
        this,
        sessionId.hashCode(),
        Intent(this, SshSessionService::class.java)
            .setAction(ACTION_DISCONNECT)
            .setData(Uri.parse("ghostty-connect://session/$sessionId/disconnect"))
            .putExtra(EXTRA_SESSION_ID, sessionId),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun onMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) action() else mainHandler.post(action)
    }

    private inline fun onServiceMain(action: () -> Unit) {
        check(Looper.myLooper() == Looper.getMainLooper()) { "Session binder calls must run on the main thread" }
        action()
    }

    private inline fun <T> onServiceMainResult(action: () -> T): T {
        check(Looper.myLooper() == Looper.getMainLooper()) { "Session binder calls must run on the main thread" }
        return action()
    }

    companion object {
        const val ACTION_DISCONNECT = "dev.ghostty.connect.action.DISCONNECT"
        const val ACTION_OPEN_SESSION = "dev.ghostty.connect.action.OPEN_SESSION"
        const val EXTRA_SESSION_ID = "dev.ghostty.connect.extra.SESSION_ID"
        fun newSessionId(): String = UUID.randomUUID().toString()

        @Volatile var active: Boolean = false
            private set
        private const val CHANNEL_ID = "ssh_sessions"
        private const val NOTIFICATION_ID = 100
        private const val REMOTE_CHANNEL_ID = "remote_terminal"
        private const val FRAME_INTERVAL_MS = 16L
        private const val STABLE_CONNECTION_MS = 60_000L
        private const val STATUS_CONNECTED = "Connected"
        private const val STATUS_WAITING_FOR_NETWORK = "Waiting for network"
        private const val STATUS_REAUTHENTICATION_REQUIRED = "Re-authentication required"
    }
}
