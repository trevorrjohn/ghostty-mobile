package dev.ghostty.connect.terminal

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Binder
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import dev.ghostty.connect.MainActivity
import dev.ghostty.connect.data.SshKeyStore
import dev.ghostty.connect.model.Host
import dev.ghostty.connect.terminal.bridge.GhosttyTerminal
import java.util.concurrent.atomic.AtomicBoolean

class SshSessionService : Service(), SshConnection.Callbacks {
    interface Listener {
        fun onSessionStatus(status: String)
        fun onTerminalChanged()
        fun onHostKeyVerification(fingerprint: String, changed: Boolean, answer: (Boolean) -> Unit)
        fun onSessionClosed(error: String?)
    }

    inner class LocalBinder : Binder() {
        val service: SshSessionService get() = this@SshSessionService
    }

    private data class PendingVerification(
        val fingerprint: String,
        val changed: Boolean,
        val answer: (Boolean) -> Unit,
    )

    private val binder = LocalBinder()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var connection: SshConnection? = null
    private var listener: Listener? = null
    private var pendingVerification: PendingVerification? = null
    private var status = "Disconnected"
    var host: Host? = null
        private set
    var terminal: GhosttyTerminal? = null
        private set

    override fun onCreate() {
        super.onCreate()
        active = true
        createNotificationChannel()
        startInForeground("Preparing connection…")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_DISCONNECT) disconnect()
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder = binder

    fun attach(listener: Listener) {
        this.listener = listener
        listener.onSessionStatus(status)
        if (terminal != null) listener.onTerminalChanged()
        pendingVerification?.let { listener.onHostKeyVerification(it.fingerprint, it.changed, it.answer) }
    }

    fun detach(listener: Listener) {
        if (this.listener === listener) this.listener = null
    }

    fun connect(host: Host, credential: String) {
        disconnectResources()
        this.host = host
        terminal = GhosttyTerminal()
        status = "Connecting…"
        startInForeground(status)
        listener?.onSessionStatus(status)
        connection = SshConnection(applicationContext, SshKeyStore(applicationContext), this).also {
            it.connect(host, credential)
        }
    }

    fun send(text: String) = connection?.send(text) ?: Unit

    fun statusText(): String = status

    fun resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        connection?.resize(columns, rows, pixelWidth, pixelHeight)
    }

    fun disconnect() {
        pendingVerification?.answer?.invoke(false)
        pendingVerification = null
        disconnectResources()
        status = "Disconnected"
        listener?.onSessionClosed(null)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun status(message: String) = onMain {
        status = message
        updateNotification(message)
        listener?.onSessionStatus(message)
    }

    override fun output(bytes: ByteArray) {
        terminal?.write(bytes)
        onMain { listener?.onTerminalChanged() }
    }

    override fun verifyHostKey(fingerprint: String, changed: Boolean, answer: (Boolean) -> Unit) {
        val answered = AtomicBoolean(false)
        val once: (Boolean) -> Unit = { accepted ->
            if (answered.compareAndSet(false, true)) {
                pendingVerification = null
                answer(accepted)
            }
        }
        onMain {
            pendingVerification = PendingVerification(fingerprint, changed, once)
            listener?.onHostKeyVerification(fingerprint, changed, once)
        }
    }

    override fun closed(error: String?) = onMain {
        connection = null
        status = if (error == null) "Disconnected" else "Connection failed"
        error?.let { terminal?.write("\r\n\r\n\u001b[31mConnection failed:\u001b[0m $it\r\n") }
        listener?.onTerminalChanged()
        listener?.onSessionClosed(error)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        active = false
        pendingVerification?.answer?.invoke(false)
        pendingVerification = null
        disconnectResources()
        super.onDestroy()
    }

    private fun disconnectResources() {
        connection?.disconnect()
        connection = null
        terminal?.close()
        terminal = null
        host = null
    }

    private fun onMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) action() else mainHandler.post(action)
    }

    private fun createNotificationChannel() {
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "SSH sessions", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shows an active background SSH connection"
                setShowBadge(false)
            },
        )
    }

    private fun startInForeground(message: String) {
        val notification = notification(message)
        startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
    }

    private fun updateNotification(message: String) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(message))
    }

    private fun notification(message: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).setAction(ACTION_OPEN_SESSION),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val disconnect = PendingIntent.getService(
            this, 1, Intent(this, SshSessionService::class.java).setAction(ACTION_DISCONNECT),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val title = host?.let { "Connected to ${it.name}" } ?: "Ghostty Connect"
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle(title)
            .setContentText(message)
            .setContentIntent(open)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(Notification.Action.Builder(null, "Disconnect", disconnect).build())
            .build()
    }

    companion object {
        const val ACTION_DISCONNECT = "dev.ghostty.connect.action.DISCONNECT"
        const val ACTION_OPEN_SESSION = "dev.ghostty.connect.action.OPEN_SESSION"
        @Volatile var active: Boolean = false
            private set
        private const val CHANNEL_ID = "ssh_sessions"
        private const val NOTIFICATION_ID = 100
    }
}
