package dev.ghostty.connect.sftp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Binder
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.provider.OpenableColumns
import dev.ghostty.connect.MainActivity
import dev.ghostty.connect.data.HostStore
import dev.ghostty.connect.data.SftpRecentFolderStore
import dev.ghostty.connect.data.SshKeyStore
import dev.ghostty.connect.model.Host
import dev.ghostty.connect.model.sameSshDestination
import dev.ghostty.connect.terminal.AuthenticationChallenge
import dev.ghostty.connect.terminal.ExactlyOnceAnswer
import dev.ghostty.connect.terminal.HostKeyVerification
import dev.ghostty.connect.terminal.SshAuthenticationCallbacks
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class SftpBrowserService : Service() {
    interface Listener {
        fun onBrowserChanged(state: SftpBrowserState)
        fun onHostKeyVerification(
            browserId: String,
            request: HostKeyVerification,
            answer: (Boolean) -> Unit,
        )
        fun onAuthenticationChallenge(
            browserId: String,
            hostName: String,
            challenge: AuthenticationChallenge,
            answer: (CharArray?) -> Unit,
        )
        fun onAuthenticationBanner(browserId: String, hostName: String, message: String)
    }

    inner class LocalBinder : Binder() {
        val service: SftpBrowserService get() = this@SftpBrowserService
    }

    private data class PendingVerification(
        val request: HostKeyVerification,
        val answer: (Boolean) -> Unit,
    )

    private data class PendingChallenge(
        val challenge: AuthenticationChallenge,
        val answer: (CharArray?) -> Unit,
    )

    private inner class BrowserRecord(
        val browserId: String,
        val host: Host,
    ) {
        val executor = Executors.newSingleThreadExecutor { task -> Thread(task, "sftp-browser") }
        val pathStack = ArrayDeque<String>()
        val credentialLock = Any()
        val pendingCredentials = mutableListOf<CharArray>()
        var connection: SftpConnection? = null
        var pendingVerification: PendingVerification? = null
        var pendingChallenge: PendingChallenge? = null
        var pendingAuthenticationBanner: String? = null
        var transferCanceled: AtomicBoolean? = null
        var transferFinished: AtomicBoolean? = null
        var busy = false
        var state = SftpBrowserState(browserId, host.name, STATUS_CONNECTING)
        var generation = 0L
    }

    private val recentFolderStore by lazy { SftpRecentFolderStore(applicationContext) }

    private inner class AttemptCallbacks(
        private val record: BrowserRecord,
        private val generation: Long,
    ) : SshAuthenticationCallbacks {
        override fun status(message: String) = onMain {
            if (isCurrent(record, generation)) update(record, record.state.copy(status = message, error = null))
        }

        override fun authenticationBanner(message: String) = onMain {
            if (!isCurrent(record, generation)) return@onMain
            record.pendingAuthenticationBanner = message
            authenticationForegroundBrowsers += record.browserId
            refreshForegroundNotification()
            update(record, record.state.copy(status = "Tailscale verification required", error = null))
            listener?.onAuthenticationBanner(record.browserId, record.host.name, message)
        }

        override fun verifyHostKey(request: HostKeyVerification, answer: (Boolean) -> Unit) {
            val once = ExactlyOnceAnswer<Boolean> { accepted ->
                onMain {
                    val current = isCurrent(record, generation)
                    if (current) record.pendingVerification = null
                    answer(accepted == true && current)
                }
            }
            val respond: (Boolean) -> Unit = { once.answer(it) }
            onMain {
                if (!isCurrent(record, generation)) {
                    respond(false)
                    return@onMain
                }
                record.pendingVerification = PendingVerification(request, respond)
                listener?.onHostKeyVerification(record.browserId, request, respond)
            }
        }

        override fun challenge(
            challenge: AuthenticationChallenge,
            answer: (CharArray?) -> Unit,
        ): () -> Unit {
            lateinit var respond: (CharArray?) -> Unit
            val once = ExactlyOnceAnswer<CharArray> { submitted ->
                onMain {
                    val current = isCurrent(record, generation) && record.pendingChallenge?.answer === respond
                    if (current) record.pendingChallenge = null
                    val owned = submitted?.copyOf()
                    submitted?.fill('\u0000')
                    if (current) answer(owned) else {
                        owned?.fill('\u0000')
                        answer(null)
                    }
                }
            }
            respond = { value -> if (!once.answer(value)) value?.fill('\u0000') }
            onMain {
                if (!isCurrent(record, generation) || once.isAnswered) {
                    respond(null)
                    return@onMain
                }
                record.pendingChallenge?.answer?.invoke(null)
                record.pendingChallenge = PendingChallenge(challenge, respond)
                listener?.onAuthenticationChallenge(record.browserId, record.host.name, challenge, respond)
            }
            return { respond(null) }
        }
    }

    private val binder = LocalBinder()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val browsers = LinkedHashMap<String, BrowserRecord>()
    private var listener: Listener? = null
    private var selectedBrowserId: String? = null
    private val authenticationForegroundBrowsers = mutableSetOf<String>()

    override fun onCreate() {
        super.onCreate()
        active = true
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "File transfers", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shows an active upload or download"
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            },
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_PREPARE_BROWSER) {
            val browserId = intent.getStringExtra(EXTRA_BROWSER_ID) ?: return START_NOT_STICKY
            startForeground(
                NOTIFICATION_ID,
                browserNotification(browserId, "Connecting to remote files"),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        }
        if (intent?.action == ACTION_CANCEL_TRANSFER) {
            intent.getStringExtra(EXTRA_BROWSER_ID)?.let { id -> onMain { cancelTransfer(id) } }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder = binder

    fun attach(listener: Listener, browserId: String?) = onServiceMain {
        this.listener = listener
        selectedBrowserId = browserId?.takeIf(browsers::containsKey)
        selectedBrowserId?.let(browsers::get)?.let(::emit)
        browsers.values.forEach { record ->
            record.pendingVerification?.let {
                listener.onHostKeyVerification(record.browserId, it.request, it.answer)
            }
            record.pendingChallenge?.let {
                listener.onAuthenticationChallenge(record.browserId, record.host.name, it.challenge, it.answer)
            }
            record.pendingAuthenticationBanner?.let {
                listener.onAuthenticationBanner(record.browserId, record.host.name, it)
            }
        }
    }

    fun detach(listener: Listener) = onServiceMain {
        if (this.listener === listener) this.listener = null
    }

    fun connect(browserId: String, host: Host, credential: CharArray, unlockedPrivateKey: ByteArray? = null) = onServiceMain {
        if (browserId.isBlank()) {
            credential.fill('\u0000')
            unlockedPrivateKey?.fill(0)
            require(browserId.isNotBlank())
        }
        if (browserId in browsers) {
            credential.fill('\u0000')
            unlockedPrivateKey?.fill(0)
            error("File browser already exists")
        }
        val record = BrowserRecord(browserId, host)
        browsers[browserId] = record
        selectedBrowserId = browserId
        emit(record)
        startAttempt(record, credential, unlockedPrivateKey)
    }

    fun retry(browserId: String, credential: CharArray, unlockedPrivateKey: ByteArray? = null) = onServiceMain {
        val record = browsers[browserId] ?: run {
            credential.fill('\u0000')
            unlockedPrivateKey?.fill(0)
            return@onServiceMain
        }
        cancelAttempt(record)
        record.pathStack.clear()
        update(record, record.state.copy(status = STATUS_CONNECTING, connected = false, error = null, entries = emptyList()))
        startAttempt(record, credential, unlockedPrivateKey)
    }

    fun state(browserId: String): SftpBrowserState? = onServiceMainResult { browsers[browserId]?.state }
    fun states(): List<SftpBrowserState> = onServiceMainResult { browsers.values.map(BrowserRecord::state) }
    fun selectBrowser(browserId: String) = onServiceMain {
        selectedBrowserId = browserId.takeIf(browsers::containsKey)
        selectedBrowserId?.let(browsers::get)?.let(::emit)
    }
    fun host(browserId: String): Host? = onServiceMainResult { browsers[browserId]?.host }
    fun hasActiveDestination(hostname: String, port: Int): Boolean = onServiceMainResult {
        browsers.values.any { sameSshDestination(it.host.hostname, it.host.port, hostname, port) }
    }
    fun hasActiveIdentity(identityId: String): Boolean = onServiceMainResult {
        browsers.values.any { it.host.identityId == identityId }
    }

    fun refresh(browserId: String) = operation(browserId, STATUS_LOADING) { record, connection ->
        refreshState(record, connection)
    }

    fun enter(browserId: String, entry: SftpEntry) = operation(browserId, STATUS_LOADING) { record, connection ->
        require(entry.type == SftpEntryType.DIRECTORY && entry.supported) { "This entry cannot be opened." }
        val next = connection.enterDirectory(record.pathStack.last(), entry.name)
        record.pathStack.addLast(next)
        refreshState(record, connection)
    }

    fun navigateBack(browserId: String) = operation(browserId, STATUS_LOADING) { record, connection ->
        if (record.pathStack.size > 1) record.pathStack.removeLast()
        refreshState(record, connection)
    }

    fun openPath(browserId: String, path: String) = operation(browserId, STATUS_LOADING) { record, connection ->
        val target = connection.openDirectoryPath(record.pathStack.last(), path)
        record.pathStack.clear()
        record.pathStack.addAll(remoteAbsolutePathStack(target))
        refreshState(record, connection)
    }

    fun createDirectory(browserId: String, name: String) = operation(browserId, "Creating folder…") { record, connection ->
        connection.createDirectory(record.pathStack.last(), name)
        refreshState(record, connection)
    }

    fun rename(browserId: String, entry: SftpEntry, newName: String) = operation(browserId, "Renaming…") { record, connection ->
        connection.rename(record.pathStack.last(), entry.name, newName)
        refreshState(record, connection)
    }

    fun delete(browserId: String, entry: SftpEntry) = operation(browserId, "Deleting…") { record, connection ->
        val storedHost = HostStore(applicationContext, SshKeyStore(applicationContext))
            .loadAll().firstOrNull { it.id == record.host.id }
        check(storedHost?.allowSftpDelete == true) { "Remote file deletion is disabled for this host." }
        connection.delete(record.pathStack.last(), entry)
        refreshState(record, connection)
    }

    fun download(
        browserId: String,
        expectedPath: String,
        entry: SftpEntry,
        destination: Uri,
        maxBytes: Long? = null,
        openWhenComplete: Boolean = false,
    ) = transfer(
        browserId,
        expectedPath,
        SftpTransferDirection.DOWNLOAD,
        entry.name,
        entry.size,
        destination.toString(),
        openWhenComplete,
    ) { record, connection, canceled, progress ->
        require(entry.type == SftpEntryType.FILE && entry.supported) { "Only regular files can be downloaded." }
        try {
            contentResolver.openOutputStream(destination, "w")?.use { output ->
                connection.download(record.pathStack.last(), entry.name, output, canceled, maxBytes, progress)
            } ?: error("The selected document could not be opened for writing.")
        } catch (error: Exception) {
            runCatching { contentResolver.delete(destination, null, null) }
            throw error
        }
    }

    fun upload(browserId: String, expectedPath: String, source: Uri, remoteName: String, replace: Boolean) {
        val total = queryDocumentSize(source)
        transfer(browserId, expectedPath, SftpTransferDirection.UPLOAD, remoteName, total) { record, connection, canceled, progress ->
            contentResolver.openInputStream(source)?.use { input ->
                connection.upload(record.pathStack.last(), remoteName, input, total, replace, canceled, progress)
            } ?: error("The selected document could not be opened for reading.")
        }
    }

    fun cancelTransfer(browserId: String) = onServiceMain {
        val record = browsers[browserId] ?: return@onServiceMain
        val transfer = record.state.transfer?.takeIf { it.status == SftpTransferStatus.RUNNING } ?: return@onServiceMain
        if (record.transferFinished?.get() == true) return@onServiceMain
        record.transferCanceled?.set(true)
        val partialMessage = if (transfer.direction == SftpTransferDirection.UPLOAD) {
            "Transfer canceled. A temporary remote file may remain if cleanup cannot be confirmed."
        } else {
            "Transfer canceled. The selected local document may be incomplete."
        }
        update(record, record.state.copy(
            transfer = transfer.copy(status = SftpTransferStatus.CANCELED, message = partialMessage),
        ))
        mainHandler.postDelayed({
            if (record.transferCanceled?.get() == true && record.transferFinished?.get() == false) {
                record.connection?.disconnect()
                record.connection = null
            }
        }, CANCEL_GRACE_MS)
    }

    fun acknowledgeTransfer(browserId: String) = onServiceMain {
        val record = browsers[browserId] ?: return@onServiceMain
        if (record.state.transfer?.status != SftpTransferStatus.RUNNING) {
            record.state.transfer?.openUri?.let(::deletePreviewUri)
            update(record, record.state.copy(transfer = null, error = null))
        }
    }

    fun close(browserId: String) = onServiceMain {
        val record = browsers.remove(browserId) ?: return@onServiceMain
        record.state.transfer?.openUri?.let(::deletePreviewUri)
        if (activeTransferBrowserId == browserId) {
            activeTransferBrowserId = null
        }
        authenticationForegroundBrowsers -= browserId
        refreshForegroundNotification()
        cancelAttempt(record)
        record.executor.shutdownNow()
        if (selectedBrowserId == browserId) selectedBrowserId = null
        if (browsers.isEmpty()) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    override fun onDestroy() {
        browsers.values.forEach { record ->
            record.state.transfer?.openUri?.let(::deletePreviewUri)
            cancelAttempt(record)
            record.executor.shutdownNow()
        }
        browsers.clear()
        activeTransferBrowserId = null
        active = false
        super.onDestroy()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        activeTransferBrowserId?.let(::cancelTransfer)
        activeTransferBrowserId = null
        refreshForegroundNotification()
    }

    private fun startAttempt(record: BrowserRecord, credential: CharArray, unlockedPrivateKey: ByteArray?) {
        val generation = ++record.generation
        val connection = SftpConnection(applicationContext, AttemptCallbacks(record, generation))
        record.connection = connection
        synchronized(record.credentialLock) { record.pendingCredentials += credential }
        try {
            record.executor.execute {
                try {
                    val home = connection.connect(record.host, credential, unlockedPrivateKey)
                    val entries = connection.list(home)
                    onMain {
                    if (!isCurrent(record, generation)) return@onMain
                    record.pendingAuthenticationBanner = null
                    authenticationForegroundBrowsers -= record.browserId
                    refreshForegroundNotification()
                    record.pathStack.clear()
                    record.pathStack.addAll(remoteAbsolutePathStack(home))
                    update(record, record.state.copy(
                            status = if (entries.isEmpty()) STATUS_EMPTY else STATUS_READY,
                            path = home,
                            entries = entries,
                        canNavigateBack = record.pathStack.size > 1,
                            connected = true,
                            error = null,
                        ))
                        recordRecentFolder(record, home)
                    }
                } catch (error: Exception) {
                    onMain { fail(record, generation, error) }
                } finally {
                    credential.fill('\u0000')
                    unlockedPrivateKey?.fill(0)
                    synchronized(record.credentialLock) { record.pendingCredentials.removeAll { it === credential } }
                }
            }
        } catch (error: RuntimeException) {
            credential.fill('\u0000')
            unlockedPrivateKey?.fill(0)
            synchronized(record.credentialLock) { record.pendingCredentials.removeAll { it === credential } }
            throw error
        }
    }

    private fun operation(
        browserId: String,
        status: String,
        action: (BrowserRecord, SftpConnection) -> Unit,
    ) = onServiceMain {
        val record = browsers[browserId] ?: return@onServiceMain
        if (record.busy || record.state.transfer?.status == SftpTransferStatus.RUNNING) {
            update(record, record.state.copy(error = "Wait for the current file operation to finish."))
            return@onServiceMain
        }
        val connection = record.connection ?: return@onServiceMain
        val generation = record.generation
        record.busy = true
        update(record, record.state.copy(status = status, error = null))
        record.executor.execute {
            try {
                action(record, connection)
            } catch (error: Exception) {
                onMain {
                    if (!isCurrent(record, generation)) return@onMain
                    record.busy = false
                    if (isSftpConnectionFailure(error)) {
                        record.connection?.disconnect()
                        record.connection = null
                        update(record, record.state.copy(
                            status = STATUS_DISCONNECTED,
                            connected = false,
                            error = failure(error),
                        ))
                    } else {
                        update(record, record.state.copy(status = STATUS_READY, error = failure(error)))
                    }
                }
            }
        }
    }

    private fun transfer(
        browserId: String,
        expectedPath: String,
        direction: SftpTransferDirection,
        displayName: String,
        total: Long?,
        openUri: String? = null,
        openWhenComplete: Boolean = false,
        action: (BrowserRecord, SftpConnection, AtomicBoolean, (Long, Long?) -> Unit) -> Unit,
    ) = onServiceMain {
        val record = browsers[browserId] ?: return@onServiceMain
        if (activeTransferBrowserId != null && activeTransferBrowserId != browserId) {
            update(record, record.state.copy(error = "Another file transfer must finish or be canceled first."))
            return@onServiceMain
        }
        if (record.busy || record.state.transfer?.status == SftpTransferStatus.RUNNING) {
            update(record, record.state.copy(error = "Finish or cancel the current transfer first."))
            return@onServiceMain
        }
        if (record.state.path != expectedPath) {
            update(record, record.state.copy(error = "The remote directory changed. Choose the document again."))
            return@onServiceMain
        }
        val connection = record.connection ?: return@onServiceMain
        val generation = record.generation
        val canceled = AtomicBoolean(false).also { record.transferCanceled = it }
        val finished = AtomicBoolean(false).also { record.transferFinished = it }
        record.busy = true
        activeTransferBrowserId = browserId
        update(record, record.state.copy(
            transfer = SftpTransferState(
                direction,
                displayName,
                0,
                total,
                SftpTransferStatus.RUNNING,
                openUri = openUri,
                openWhenComplete = openWhenComplete,
            ),
            error = null,
        ))
        startTransferForeground(record)
        record.executor.execute {
            var latestTransferred = 0L
            var latestTotal = total
            var lastProgressUpdateAt = 0L
            try {
                action(record, connection, canceled) { transferred, knownTotal ->
                    latestTransferred = transferred
                    latestTotal = knownTotal
                    val now = SystemClock.elapsedRealtime()
                    if (now - lastProgressUpdateAt < PROGRESS_UPDATE_INTERVAL_MS) return@action
                    lastProgressUpdateAt = now
                    onMain {
                        if (!isCurrent(record, generation) || canceled.get()) return@onMain
                        val current = record.state.transfer ?: return@onMain
                        update(record, record.state.copy(transfer = current.copy(transferred = transferred, total = knownTotal)))
                        updateTransferNotification(record)
                    }
                }
                finished.set(true)
                onMain {
                    if (!isCurrent(record, generation)) return@onMain
                    record.busy = false
                    if (activeTransferBrowserId == browserId) {
                        activeTransferBrowserId = null
                        refreshForegroundNotification()
                    }
                    val current = record.state.transfer ?: return@onMain
                    update(record, record.state.copy(
                        transfer = current.copy(
                            transferred = latestTransferred,
                            total = latestTotal,
                            status = SftpTransferStatus.COMPLETED,
                            message = if (canceled.get()) {
                                "Transfer completed before cancellation took effect."
                            } else "Transfer complete.",
                        ),
                    ))
                    refresh(browserId)
                }
            } catch (error: Exception) {
                onMain {
                    if (!isCurrent(record, generation)) return@onMain
                    record.busy = false
                    finished.set(true)
                    if (activeTransferBrowserId == browserId) {
                        activeTransferBrowserId = null
                        refreshForegroundNotification()
                    }
                    if (canceled.get()) {
                        if (record.connection == null) update(record, record.state.copy(
                            status = STATUS_DISCONNECTED,
                            connected = false,
                            error = "Reconnect to continue browsing.",
                        ))
                        return@onMain
                    }
                    val current = record.state.transfer ?: return@onMain
                    if (isSftpConnectionFailure(error)) {
                        record.connection?.disconnect()
                        record.connection = null
                        update(record, record.state.copy(
                            status = STATUS_DISCONNECTED,
                            connected = false,
                            transfer = current.copy(status = SftpTransferStatus.FAILED, message = failure(error)),
                            error = failure(error),
                        ))
                    } else update(record, record.state.copy(
                        transfer = current.copy(status = SftpTransferStatus.FAILED, message = failure(error)), error = failure(error),
                    ))
                }
            }
        }
    }

    private fun refreshState(record: BrowserRecord, connection: SftpConnection) {
        val path = record.pathStack.last()
        val entries = connection.list(path)
        onMain {
            if (!browsers.containsKey(record.browserId)) return@onMain
            record.busy = false
            record.pendingAuthenticationBanner = null
            authenticationForegroundBrowsers -= record.browserId
            refreshForegroundNotification()
            update(record, record.state.copy(
                status = if (entries.isEmpty()) STATUS_EMPTY else STATUS_READY,
                path = path,
                entries = entries,
                canNavigateBack = record.pathStack.size > 1,
                connected = true,
                error = null,
            ))
            recordRecentFolder(record, path)
        }
    }

    private fun recordRecentFolder(record: BrowserRecord, path: String) {
        runCatching {
            record.executor.execute {
                val changed = runCatching { recentFolderStore.record(record.host.id, path) }.getOrDefault(false)
                if (changed) onMain {
                    if (browsers[record.browserId] === record && record.state.path == path) emit(record)
                }
            }
        }
    }

    private fun fail(record: BrowserRecord, generation: Long, error: Exception) {
        if (!isCurrent(record, generation)) return
        record.connection?.disconnect()
        record.connection = null
        authenticationForegroundBrowsers -= record.browserId
        refreshForegroundNotification()
        update(record, record.state.copy(status = STATUS_FAILED, connected = false, error = failure(error)))
    }

    private fun failure(error: Throwable): String = when (error) {
        is IllegalArgumentException, is IllegalStateException -> error.message ?: sftpFailureMessage(error)
        else -> sftpFailureMessage(error)
    }

    private fun cancelAttempt(record: BrowserRecord) {
        record.generation++
        record.transferCanceled?.set(true)
        record.pendingVerification?.answer?.invoke(false)
        record.pendingVerification = null
        record.pendingChallenge?.answer?.invoke(null)
        record.pendingChallenge = null
        record.pendingAuthenticationBanner = null
        authenticationForegroundBrowsers -= record.browserId
        refreshForegroundNotification()
        record.connection?.disconnect()
        record.connection = null
        synchronized(record.credentialLock) {
            record.pendingCredentials.forEach { it.fill('\u0000') }
            record.pendingCredentials.clear()
        }
    }

    private fun update(record: BrowserRecord, state: SftpBrowserState) {
        if (browsers[record.browserId] !== record) return
        record.state = state
        emit(record)
    }

    private fun emit(record: BrowserRecord) {
        if (selectedBrowserId == record.browserId) listener?.onBrowserChanged(record.state)
    }

    private fun isCurrent(record: BrowserRecord, generation: Long): Boolean =
        browsers[record.browserId] === record && record.generation == generation

    private fun queryDocumentSize(uri: Uri): Long? = runCatching {
        contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else null
        }
    }.getOrNull()

    private fun deletePreviewUri(uriString: String) {
        val uri = Uri.parse(uriString)
        if (uri.authority == "$packageName.sftp-previews") {
            runCatching { contentResolver.delete(uri, null, null) }
        }
    }

    private fun startTransferForeground(record: BrowserRecord) {
        refreshForegroundNotification()
    }

    private fun updateTransferNotification(record: BrowserRecord) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, transferNotification(record))
    }

    private fun transferNotification(record: BrowserRecord): Notification {
        val transfer = record.state.transfer
        val total = transfer?.total
        val progress = if (total != null && total > 0) ((transfer.transferred * 100) / total).toInt() else 0
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(if (transfer?.direction == SftpTransferDirection.UPLOAD) {
                android.R.drawable.stat_sys_upload
            } else {
                android.R.drawable.stat_sys_download
            })
            .setContentTitle(if (transfer?.direction == SftpTransferDirection.UPLOAD) "Uploading document" else "Downloading document")
            .setContentText(if (total == null) "Transfer in progress" else "$progress%")
            .setProgress(100, progress, total == null)
            .setContentIntent(openBrowserIntent(record.browserId))
            .addAction(Notification.Action.Builder(null, "Open", openBrowserIntent(record.browserId)).build())
            .addAction(Notification.Action.Builder(null, "Cancel", cancelIntent(record.browserId)).build())
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setLocalOnly(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun refreshForegroundNotification() {
        val transferRecord = activeTransferBrowserId?.let(browsers::get)
        if (transferRecord != null) {
            val type = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC or
                (if (authenticationForegroundBrowsers.isNotEmpty()) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0)
            startForeground(NOTIFICATION_ID, transferNotification(transferRecord), type)
            return
        }
        val browserId = authenticationForegroundBrowsers.firstOrNull()
        if (browserId != null) {
            startForeground(
                NOTIFICATION_ID,
                browserNotification(browserId, "Return after SSH verification"),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            stopForeground(STOP_FOREGROUND_REMOVE)
        }
    }

    private fun browserNotification(browserId: String, message: String): Notification =
        Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("Remote files")
            .setContentText(message)
            .setContentIntent(openBrowserIntent(browserId))
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setLocalOnly(true)
            .build()

    private fun openBrowserIntent(browserId: String): PendingIntent = PendingIntent.getActivity(
        this,
        browserId.hashCode(),
        Intent(this, MainActivity::class.java)
            .setAction(ACTION_OPEN_BROWSER)
            .setData(Uri.parse("ghostty-connect://files/$browserId/open"))
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(EXTRA_BROWSER_ID, browserId),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun cancelIntent(browserId: String): PendingIntent = PendingIntent.getService(
        this,
        browserId.hashCode(),
        Intent(this, SftpBrowserService::class.java)
            .setAction(ACTION_CANCEL_TRANSFER)
            .setData(Uri.parse("ghostty-connect://files/$browserId/cancel"))
            .putExtra(EXTRA_BROWSER_ID, browserId),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun onMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) action() else mainHandler.post(action)
    }

    private inline fun onServiceMain(action: () -> Unit) {
        check(Looper.myLooper() == Looper.getMainLooper()) { "SFTP binder calls must run on the main thread" }
        action()
    }

    private inline fun <T> onServiceMainResult(action: () -> T): T {
        check(Looper.myLooper() == Looper.getMainLooper()) { "SFTP binder calls must run on the main thread" }
        return action()
    }

    companion object {
        const val ACTION_PREPARE_BROWSER = "dev.ghostty.connect.action.PREPARE_FILES"
        const val ACTION_OPEN_BROWSER = "dev.ghostty.connect.action.OPEN_FILES"
        const val ACTION_CANCEL_TRANSFER = "dev.ghostty.connect.action.CANCEL_FILE_TRANSFER"
        const val EXTRA_BROWSER_ID = "dev.ghostty.connect.extra.BROWSER_ID"
        fun newBrowserId(): String = UUID.randomUUID().toString()

        @Volatile var active: Boolean = false
            private set

        private const val CHANNEL_ID = "sftp_transfers"
        private const val NOTIFICATION_ID = 200
        private const val CANCEL_GRACE_MS = 1_000L
        private const val PROGRESS_UPDATE_INTERVAL_MS = 250L
        private const val STATUS_CONNECTING = "Connecting"
        private const val STATUS_LOADING = "Loading"
        private const val STATUS_READY = "Ready"
        private const val STATUS_EMPTY = "Empty"
        private const val STATUS_DISCONNECTED = "Disconnected"
        private const val STATUS_FAILED = "Failed"
        private var activeTransferBrowserId: String? = null
    }
}
