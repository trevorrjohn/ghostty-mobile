package dev.ghostty.connect.terminal

import android.content.Context
import dev.ghostty.connect.BuildConfig
import dev.ghostty.connect.data.SshKeyStore
import dev.ghostty.connect.model.Host
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.ConnectionException
import net.schmizz.sshj.connection.channel.direct.Session
import net.schmizz.sshj.connection.channel.direct.Signal
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

class SshConnection(
    private val context: Context,
    private val keyStore: SshKeyStore,
    private val callbacks: Callbacks,
) {
    private val channelExecutor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "ssh-channel")
    }

    interface Callbacks : SshAuthenticationCallbacks {
        fun output(bytes: ByteArray)
        fun connected()
        fun closed(closure: SshClosure)
    }

    private var client: SSHClient? = null
    private var session: Session? = null
    private var shell: Session.Shell? = null
    @Volatile private var stopping = false
    @Volatile private var columns = 80
    @Volatile private var rows = 24
    @Volatile private var pixelWidth = 0
    @Volatile private var pixelHeight = 0
    private val closureReported = AtomicBoolean(false)

    fun connect(host: Host, passwordOrPassphrase: CharArray) = thread(name = "ssh-${host.hostname}") {
        try {
            val ssh = AuthenticatedSshClient(context, keyStore, callbacks)
                .connect(host, passwordOrPassphrase) { client = it }
            val activeSession = ssh.startSession().also { session = it }
            setOptionalEnvironment(activeSession, "COLORTERM", "truecolor")
            setOptionalEnvironment(activeSession, "TERM_PROGRAM", "ghostty")
            setOptionalEnvironment(activeSession, "TERM_PROGRAM_VERSION", BuildConfig.VERSION_NAME)
            activeSession.allocatePTY("xterm-256color", columns, rows, pixelWidth, pixelHeight, emptyMap())
            val activeShell = activeSession.startShell().also { shell = it }
            callbacks.connected()
            thread(name = "ssh-stderr", isDaemon = true) {
                val errorBuffer = ByteArray(4096)
                runCatching {
                    while (!stopping) {
                        val count = activeShell.errorStream.read(errorBuffer)
                        if (count < 0) break
                        if (count > 0) callbacks.output(errorBuffer.copyOf(count))
                    }
                }
            }
            val buffer = ByteArray(8192)
            while (!stopping) {
                val count = activeShell.inputStream.read(buffer)
                if (count < 0) break
                callbacks.output(buffer.copyOf(count))
            }
            if (!stopping) reportClosed(null)
        } catch (error: Exception) {
            if (!stopping) reportClosed(error)
        } finally {
            passwordOrPassphrase.fill('\u0000')
            closeResources()
        }
    }

    fun send(text: String) {
        send(text.toByteArray())
    }

    fun send(bytes: ByteArray) {
        if (stopping) return
        runCatching { channelExecutor.execute {
            runCatching {
                shell?.outputStream?.apply {
                    write(bytes)
                    flush()
                }
            }.onFailure(::reportClosed)
        } }
    }

    fun resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        this.columns = columns
        this.rows = rows
        this.pixelWidth = pixelWidth
        this.pixelHeight = pixelHeight
        if (stopping) return
        runCatching { channelExecutor.execute {
            runCatching { shell?.changeWindowDimensions(columns, rows, pixelWidth, pixelHeight) }
        } }
    }

    fun signal(signal: Signal) {
        if (stopping) return
        runCatching { channelExecutor.execute { runCatching { shell?.signal(signal) } } }
    }

    fun disconnect() {
        stopping = true
        closeResources()
    }

    private fun setOptionalEnvironment(session: Session, name: String, value: String) {
        try {
            session.setEnvVar(name, value)
        } catch (error: ConnectionException) {
            if (error.message != "Request failed") throw error
        }
    }

    private fun closeResources() {
        channelExecutor.shutdownNow()
        runCatching { shell?.close() }
        runCatching { session?.close() }
        runCatching { client?.disconnect() }
    }

    private fun reportClosed(error: Throwable?) {
        if (!stopping && closureReported.compareAndSet(false, true)) {
            callbacks.closed(classifySshClosure(error))
        }
    }

}
