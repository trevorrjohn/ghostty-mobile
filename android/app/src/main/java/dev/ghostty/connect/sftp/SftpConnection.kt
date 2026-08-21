package dev.ghostty.connect.sftp

import android.content.Context
import dev.ghostty.connect.data.SshKeyStore
import dev.ghostty.connect.model.Host
import dev.ghostty.connect.terminal.AuthenticatedSshClient
import dev.ghostty.connect.terminal.SshAuthenticationCallbacks
import java.io.InputStream
import java.io.OutputStream
import java.util.EnumSet
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.sftp.FileAttributes
import net.schmizz.sshj.sftp.FileMode
import net.schmizz.sshj.sftp.OpenMode
import net.schmizz.sshj.sftp.RenameFlags
import net.schmizz.sshj.sftp.Response
import net.schmizz.sshj.sftp.SFTPClient
import net.schmizz.sshj.sftp.SFTPException

internal class SftpConnection(
    private val context: Context,
    private val callbacks: SshAuthenticationCallbacks,
) {
    @Volatile private var ssh: SSHClient? = null
    @Volatile private var sftp: SFTPClient? = null
    private val closed = AtomicBoolean(false)

    fun connect(host: Host, credential: CharArray): String {
        check(!closed.get())
        val connectedSsh = AuthenticatedSshClient(context, SshKeyStore(context), callbacks)
            .connect(host, credential) { ssh = it }
        val connectedSftp = connectedSsh.newSFTPClient()
        connectedSftp.sftpEngine.timeoutMs = IO_TIMEOUT_MS
        sftp = connectedSftp
        return connectedSftp.canonicalize(".")
    }

    fun list(path: String): List<SftpEntry> = client().ls(path)
        .asSequence()
        .filterNot { it.name == "." || it.name == ".." }
        .map { resource ->
            val validName = safeRemoteChildName(resource.name)
            val attrs = resource.attributes
            val type = when (attrs.type) {
                FileMode.Type.REGULAR -> SftpEntryType.FILE
                FileMode.Type.DIRECTORY -> SftpEntryType.DIRECTORY
                FileMode.Type.SYMLINK -> SftpEntryType.SYMLINK
                else -> SftpEntryType.UNSUPPORTED
            }
            SftpEntry(
                name = resource.name,
                type = type,
                size = attrs.size.takeIf { type == SftpEntryType.FILE && attrs.has(FileAttributes.Flag.SIZE) },
                modifiedAtSeconds = attrs.mtime.takeIf { attrs.has(FileAttributes.Flag.ACMODTIME) },
                accessedAtSeconds = attrs.atime.takeIf { attrs.has(FileAttributes.Flag.ACMODTIME) },
                permissions = attrs.mode.permissionsMask.takeIf { attrs.has(FileAttributes.Flag.MODE) }
                    ?.let { "%04o".format(it) },
                supported = validName && type != SftpEntryType.UNSUPPORTED,
            )
        }
        .sortedWith(compareBy<SftpEntry>({ it.type != SftpEntryType.DIRECTORY }, { it.name.lowercase() }, { it.name }))
        .toList()

    fun enterDirectory(currentPath: String, name: String): String {
        val path = childPath(currentPath, name)
        requireType(path, FileMode.Type.DIRECTORY)
        return client().canonicalize(path)
    }

    fun openDirectoryPath(currentPath: String, input: String): String {
        val requested = input.trim()
        require(requested.isNotEmpty()) { "Enter a remote path." }
        require('\u0000' !in requested) { "Remote paths cannot contain NUL characters." }
        require(requested.toByteArray(Charsets.UTF_8).size <= MAX_REMOTE_PATH_BYTES) { "The remote path is too long." }
        val candidate = client().canonicalize(
            if (requested.startsWith('/')) requested else if (currentPath == "/") "/$requested" else "$currentPath/$requested",
        )
        requireType(candidate, FileMode.Type.DIRECTORY)
        return candidate
    }

    fun createDirectory(currentPath: String, name: String) {
        val path = childPath(currentPath, name)
        require(lstatOrNull(path) == null) { "A destination already exists." }
        client().mkdir(path)
    }

    fun rename(currentPath: String, oldName: String, newName: String) {
        val oldPath = childPath(currentPath, oldName)
        val newPath = childPath(currentPath, newName)
        client().lstat(oldPath)
        require(lstatOrNull(newPath) == null) { "A destination already exists." }
        client().rename(oldPath, newPath)
    }

    fun delete(currentPath: String, entry: SftpEntry) {
        val path = childPath(currentPath, entry.name)
        val actual = client().lstat(path).type
        when (actual) {
            FileMode.Type.DIRECTORY -> client().rmdir(path)
            FileMode.Type.REGULAR, FileMode.Type.SYMLINK -> client().rm(path)
            else -> error("The remote entry is unsupported.")
        }
    }

    fun download(
        currentPath: String,
        name: String,
        output: OutputStream,
        canceled: AtomicBoolean,
        maxBytes: Long? = null,
        progress: (Long, Long?) -> Unit,
    ) {
        val path = childPath(currentPath, name)
        val attrs = requireType(path, FileMode.Type.REGULAR)
        val total = attrs.size.takeIf { attrs.has(FileAttributes.Flag.SIZE) }
        if (maxBytes != null && total != null) require(total <= maxBytes) {
            "This file is too large to open directly. Download it instead."
        }
        client().open(path, EnumSet.of(OpenMode.READ)).use { remote ->
            val buffer = ByteArray(TRANSFER_BUFFER_BYTES)
            var offset = 0L
            while (!canceled.get()) {
                val count = remote.read(offset, buffer, 0, buffer.size)
                if (count < 0) break
                if (count == 0) continue
                if (maxBytes != null && offset + count > maxBytes) {
                    error("This file is too large to open directly. Download it instead.")
                }
                output.write(buffer, 0, count)
                offset += count
                progress(offset, total)
            }
            check(!canceled.get()) { "Transfer canceled" }
            output.flush()
        }
    }

    fun upload(
        currentPath: String,
        finalName: String,
        input: InputStream,
        total: Long?,
        replace: Boolean,
        canceled: AtomicBoolean,
        progress: (Long, Long?) -> Unit,
    ) {
        val finalPath = childPath(currentPath, finalName)
        val existing = lstatOrNull(finalPath)
        if (existing != null && !replace) error("A destination already exists.")
        if (existing?.type == FileMode.Type.DIRECTORY || existing?.type == FileMode.Type.SYMLINK) {
            error("Only an existing regular file can be replaced.")
        }
        val tempName = ".ghostty-upload-${UUID.randomUUID()}"
        val tempPath = childPath(currentPath, tempName)
        var published = false
        try {
            client().open(tempPath, EnumSet.of(OpenMode.WRITE, OpenMode.CREAT, OpenMode.EXCL)).use { remote ->
                val buffer = ByteArray(TRANSFER_BUFFER_BYTES)
                var offset = 0L
                while (!canceled.get()) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (count == 0) continue
                    remote.write(offset, buffer, 0, count)
                    offset += count
                    progress(offset, total)
                }
                check(!canceled.get()) { "Transfer canceled" }
            }
            check(!canceled.get()) { "Transfer canceled" }
            if (replace) {
                check(client().sftpEngine.supportsServerExtension("posix-rename", "openssh.com")) {
                    "This server cannot replace the destination atomically. Rename the upload instead."
                }
                client().rename(tempPath, finalPath, EnumSet.of(RenameFlags.OVERWRITE, RenameFlags.ATOMIC))
            } else {
                check(lstatOrNull(finalPath) == null) { "A destination already exists." }
                client().rename(tempPath, finalPath)
            }
            published = true
        } finally {
            if (!published) runCatching { client().rm(tempPath) }
        }
    }

    fun exists(currentPath: String, name: String): Boolean = lstatOrNull(childPath(currentPath, name)) != null

    fun disconnect() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { sftp?.close() }
        runCatching { ssh?.disconnect() }
        sftp = null
        ssh = null
    }

    private fun client(): SFTPClient = checkNotNull(sftp) { "SFTP is disconnected." }

    private fun childPath(currentPath: String, name: String): String {
        remoteChildNameError(name)?.let { error(it) }
        return if (currentPath == "/") "/$name" else "$currentPath/$name"
    }

    private fun requireType(path: String, expected: FileMode.Type): FileAttributes = client().lstat(path).also {
        require(it.type == expected) { "The remote entry is not a supported ${expected.name.lowercase()}." }
    }

    private fun lstatOrNull(path: String): FileAttributes? = try {
        client().lstat(path)
    } catch (error: SFTPException) {
        if (error.statusCode == Response.StatusCode.NO_SUCH_FILE || error.statusCode == Response.StatusCode.NO_SUCH_PATH) null
        else throw error
    }

    companion object {
        private const val IO_TIMEOUT_MS = 30_000
        private const val TRANSFER_BUFFER_BYTES = 64 * 1024
        private const val MAX_REMOTE_PATH_BYTES = 4096
    }
}
