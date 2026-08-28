package dev.ghostty.connect.terminal

import android.net.ConnectivityManager
import android.net.DnsResolver
import android.os.CancellationSignal
import android.content.Context
import dev.ghostty.connect.BuildConfig
import dev.ghostty.connect.data.SshKeyStore
import dev.ghostty.connect.model.Host
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.ConnectionException
import net.schmizz.sshj.connection.channel.direct.Session
import net.schmizz.sshj.connection.channel.direct.Signal
import java.net.InetAddress
import java.net.UnknownHostException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.Executor
import kotlin.concurrent.thread

internal fun interface SshConnector {
    fun connect(host: Host, credential: CharArray, ownClient: (SSHClient) -> Unit): SSHClient
}

internal class AndroidHostResolver(context: Context) {
    private val network = context.getSystemService(ConnectivityManager::class.java).activeNetwork

    fun resolve(hostname: String): InetAddress {
        val completed = CountDownLatch(1)
        val cancellation = CancellationSignal()
        var addresses: List<InetAddress>? = null
        var failure: DnsResolver.DnsException? = null
        DnsResolver.getInstance().query(
            network,
            hostname,
            DnsResolver.FLAG_EMPTY,
            Executor(Runnable::run),
            cancellation,
            object : DnsResolver.Callback<List<InetAddress>> {
                override fun onAnswer(answer: List<InetAddress>, rcode: Int) {
                    addresses = answer
                    completed.countDown()
                }

                override fun onError(error: DnsResolver.DnsException) {
                    failure = error
                    completed.countDown()
                }
            },
        )
        try {
            completed.await()
        } catch (error: InterruptedException) {
            cancellation.cancel()
            throw error
        }
        failure?.let { throw UnknownHostException(it.message).apply { initCause(it) } }
        val address = addresses?.firstOrNull() ?: throw UnknownHostException(hostname)
        return InetAddress.getByAddress(hostname, address.address)
    }
}

class SshConnection internal constructor(
    private val callbacks: Callbacks,
    private val connector: SshConnector,
    private val clientCloser: (SSHClient) -> Unit = { it.disconnect() },
) {
    constructor(context: Context, keyStore: SshKeyStore, callbacks: Callbacks) : this(
        callbacks,
        SshConnector { host, credential, ownClient ->
            val address = AndroidHostResolver(context).resolve(host.hostname)
            AuthenticatedSshClient(context, keyStore, callbacks).connect(
                host,
                credential,
                resolvedAddress = address,
                disconnectOnFailure = false,
                clientReady = ownClient,
            )
        },
    )

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
    private var connectionThread: Thread? = null
    private var finished = false
    private val finishCallbacks = mutableListOf<() -> Unit>()
    private val resourceLock = Any()
    private val closeLock = Any()
    @Volatile private var stopping = false
    @Volatile private var columns = 80
    @Volatile private var rows = 24
    @Volatile private var pixelWidth = 0
    @Volatile private var pixelHeight = 0
    private val closureReported = AtomicBoolean(false)

    fun connect(host: Host, passwordOrPassphrase: CharArray) {
        val worker = thread(name = "ssh-${host.hostname}", start = false) {
            try {
                val ssh = connector.connect(host, passwordOrPassphrase, ::ownClient)
                val activeSession = ownSession(ssh.startSession())
                setOptionalEnvironment(activeSession, "COLORTERM", "truecolor")
                setOptionalEnvironment(activeSession, "TERM_PROGRAM", "ghostty")
                setOptionalEnvironment(activeSession, "TERM_PROGRAM_VERSION", BuildConfig.VERSION_NAME)
                activeSession.allocatePTY("xterm-256color", columns, rows, pixelWidth, pixelHeight, emptyMap())
                val activeShell = ownShell(activeSession.startShell())
                callbacks.connected()
                thread(name = "ssh-stderr", isDaemon = true) {
                    val errorBuffer = ByteArray(4096)
                    runCatching {
                        while (!stopping) {
                            val count = activeShell.errorStream.read(errorBuffer)
                            if (count < 0) break
                            if (count > 0 && !stopping) callbacks.output(errorBuffer.copyOf(count))
                        }
                    }.onFailure(::reportClosed)
                }
                val buffer = ByteArray(8192)
                while (!stopping) {
                    val count = activeShell.inputStream.read(buffer)
                    if (count < 0) break
                    if (!stopping) callbacks.output(buffer.copyOf(count))
                }
                if (!stopping) reportClosed(null)
            } catch (error: Exception) {
                if (!stopping) reportClosed(error)
            } finally {
                passwordOrPassphrase.fill('\u0000')
                closeResources()
                finish()
            }
        }
        val start = synchronized(resourceLock) {
            if (stopping || connectionThread != null) false else {
                connectionThread = worker
                true
            }
        }
        if (start) {
            worker.start()
        } else {
            passwordOrPassphrase.fill('\u0000')
            finish()
        }
    }

    fun whenFinished(callback: () -> Unit) {
        val runNow = synchronized(resourceLock) {
            if (finished) true else {
                finishCallbacks += callback
                false
            }
        }
        if (runNow) callback()
    }

    private fun finish() {
        val callbacks = synchronized(resourceLock) {
            if (finished) return
            finished = true
            connectionThread = null
            finishCallbacks.toList().also { finishCallbacks.clear() }
        }
        callbacks.forEach { it() }
    }

    fun send(text: String) {
        send(text.toByteArray())
    }

    fun send(bytes: ByteArray) {
        if (stopping) return
        runCatching {
            channelExecutor.execute {
                runCatching {
                    val activeShell = synchronized(resourceLock) { shell }
                        ?: error("SSH shell is not available")
                    activeShell.outputStream.apply {
                    write(bytes)
                    flush()
                    }
                }.onFailure(::reportClosed)
            }
        }.onFailure(::reportClosed)
    }

    fun resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        this.columns = columns
        this.rows = rows
        this.pixelWidth = pixelWidth
        this.pixelHeight = pixelHeight
        if (stopping) return
        runCatching {
            channelExecutor.execute {
                runCatching {
                    synchronized(resourceLock) { shell }
                        ?.changeWindowDimensions(columns, rows, pixelWidth, pixelHeight)
                }.onFailure(::reportClosed)
            }
        }.onFailure(::reportClosed)
    }

    fun signal(signal: Signal) {
        if (stopping) return
        runCatching {
            channelExecutor.execute {
                runCatching {
                    val activeShell = synchronized(resourceLock) { shell }
                        ?: error("SSH shell is not available")
                    activeShell.signal(signal)
                }.onFailure(::reportClosed)
            }
        }.onFailure(::reportClosed)
    }

    fun disconnect() {
        val worker = synchronized(resourceLock) {
            if (stopping) false else {
                stopping = true
                true
            }
        }
        if (!worker) return
        channelExecutor.shutdownNow()
        synchronized(resourceLock) { connectionThread }?.interrupt()
        thread(name = "ssh-close", isDaemon = true, block = ::closeResources)
    }

    private fun setOptionalEnvironment(session: Session, name: String, value: String) {
        try {
            session.setEnvVar(name, value)
        } catch (error: ConnectionException) {
            if (error.message != "Request failed") throw error
        }
    }

    private fun closeResources() {
        synchronized(closeLock) {
            channelExecutor.shutdownNow()
            val resources = synchronized(resourceLock) {
                Triple(shell, session, client).also {
                    shell = null
                    session = null
                    client = null
                }
            }
            runCatching { resources.third?.let(clientCloser) }
            runCatching { resources.first?.close() }
            runCatching { resources.second?.close() }
        }
    }

    private fun reportClosed(error: Throwable?) {
        val report = synchronized(resourceLock) {
            if (stopping || !closureReported.compareAndSet(false, true)) false
            else {
                stopping = true
                true
            }
        }
        if (!report) return
        callbacks.closed(classifySshClosure(error))
        closeResources()
    }

    private fun ownClient(value: SSHClient) = synchronized(resourceLock) {
        if (stopping) throw CancellationException("SSH connection was cancelled")
        client = value
    }

    private fun ownSession(value: Session): Session {
        val accepted = synchronized(resourceLock) {
            if (stopping) false else {
                session = value
                true
            }
        }
        if (!accepted) {
            runCatching(value::close)
            throw CancellationException("SSH connection was cancelled")
        }
        return value
    }

    private fun ownShell(value: Session.Shell): Session.Shell {
        val accepted = synchronized(resourceLock) {
            if (stopping) false else {
                shell = value
                true
            }
        }
        if (!accepted) {
            runCatching(value::close)
            throw CancellationException("SSH connection was cancelled")
        }
        return value
    }

}
