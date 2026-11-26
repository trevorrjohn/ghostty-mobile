package dev.ghostty.connect.sftp

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import dev.ghostty.connect.terminal.AuthenticationChallenge
import dev.ghostty.connect.terminal.HostKeyVerification
import dev.ghostty.connect.terminal.SshAuthenticationCallbacks
import java.io.File
import java.io.IOException
import java.time.Instant
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread
import net.schmizz.sshj.SSHClient

/** An image copied into app-private cache, so the picker's or sender's URI grant can lapse safely. */
data class StagedImage(val file: File, val mimeType: String, val source: ImageUploadSource)

sealed interface ImageUploadUiState {
    data object Idle : ImageUploadUiState
    data class Running(val name: String, val transferred: Long, val total: Long?, val index: Int, val count: Int) : ImageUploadUiState
    data class Failed(val message: String, val canRetry: Boolean = true) : ImageUploadUiState
}

data class ImageUploadOutcome(val sessionId: String, val remotePaths: List<String>, val note: String?)

/**
 * Process-wide so an upload survives activity recreation. Everything user-visible goes through
 * [Listener] on the main thread; results with no listener attached are held until one is.
 */
object ImageUploadManager {
    interface Listener {
        fun onImageUploadState(state: ImageUploadUiState)
        fun onImageUploadFinished(outcome: ImageUploadOutcome)
    }

    private class Job(
        val sessionId: String,
        val images: MutableList<StagedImage>,
        val terminalDirectory: String?,
        val liveClient: () -> SSHClient?,
    ) {
        val canceled = AtomicBoolean(false)
        val uploaded = mutableListOf<String>()
        var fellBack = false
        val total = images.size
    }

    private val main = Handler(Looper.getMainLooper())
    private var listener: Listener? = null
    private var state: ImageUploadUiState = ImageUploadUiState.Idle
    private var undelivered: ImageUploadOutcome? = null
    private var job: Job? = null

    /** Images that arrived through a share-in and still need a target session. */
    @Volatile var stagedShare: List<StagedImage> = emptyList()

    /** Saved host a share-in is waiting to connect to, with the images to send once it does. */
    @Volatile var awaitingHost: Pair<String, List<StagedImage>>? = null

    /** Session a picker or camera request was started from, kept across activity recreation. */
    @Volatile var pickerSessionId: String? = null
    @Volatile var cameraFile: File? = null

    fun attach(value: Listener) {
        listener = value
        value.onImageUploadState(state)
        undelivered?.let { undelivered = null; value.onImageUploadFinished(it) }
    }

    fun detach(value: Listener) {
        if (listener === value) listener = null
    }

    val busy: Boolean get() = job != null

    fun cacheDirectory(context: Context): File = File(context.cacheDir, "image-uploads").apply {
        check(isDirectory || mkdirs()) { "Image cache could not be created." }
    }

    fun clearCache(context: Context) {
        if (job == null && stagedShare.isEmpty() && awaitingHost == null) {
            cacheDirectory(context).listFiles().orEmpty().forEach(File::delete)
        }
    }

    fun newCameraFile(context: Context): File = File(cacheDirectory(context), "camera-${UUID.randomUUID()}.jpg")

    /** Copies [uris] into cache off the main thread, skipping anything that is not a readable bounded image. */
    fun stage(context: Context, uris: List<Uri>, source: ImageUploadSource, onReady: (List<StagedImage>, String?) -> Unit) {
        val app = context.applicationContext
        thread(name = "image-stage", isDaemon = true) {
            val staged = mutableListOf<StagedImage>()
            var problem: String? = null
            for (uri in uris.take(MAX_IMAGES_PER_UPLOAD)) {
                val mime = app.contentResolver.getType(uri)
                if (uri.scheme != "content" || !isUploadableImageMime(mime)) {
                    problem = "Only images can be uploaded."
                    continue
                }
                val file = File(cacheDirectory(app), "staged-${UUID.randomUUID()}")
                try {
                    val input = app.contentResolver.openInputStream(uri) ?: throw IOException("The image could not be opened.")
                    input.use { stream -> file.outputStream().use { copyBounded(stream, it, MAX_IMAGE_UPLOAD_BYTES) } }
                    staged += StagedImage(file, mime!!, source)
                } catch (error: Exception) {
                    file.delete()
                    problem = error.message ?: "The image could not be read."
                }
            }
            main.post { onReady(staged, problem) }
        }
    }

    fun discard(images: List<StagedImage>) = images.forEach { it.file.delete() }

    fun start(context: Context, sessionId: String, images: List<StagedImage>, terminalDirectory: String?, liveClient: () -> SSHClient?) {
        if (job != null) {
            discard(images)
            publish(state)
            return
        }
        run(context.applicationContext, Job(sessionId, images.toMutableList(), terminalDirectory, liveClient))
    }

    fun retry(context: Context) {
        val failed = job ?: return
        if (state !is ImageUploadUiState.Failed) return
        failed.canceled.set(false)
        run(context.applicationContext, failed)
    }

    fun cancel() {
        job?.canceled?.set(true)
    }

    /** Called when a session ends so its upload stops with an honest message. */
    fun sessionEnded(sessionId: String) {
        job?.takeIf { it.sessionId == sessionId }?.canceled?.set(true)
    }

    fun dismiss() {
        job?.images?.let(::discard)
        job = null
        publish(ImageUploadUiState.Idle)
    }

    private fun publish(value: ImageUploadUiState) {
        main.post {
            state = value
            listener?.onImageUploadState(value)
        }
    }

    private fun run(app: Context, current: Job) {
        job = current
        publish(ImageUploadUiState.Running("", 0, null, 0, current.total))
        thread(name = "image-upload", isDaemon = true) {
            var connection: SftpConnection? = null
            try {
                val ssh = current.liveClient() ?: throw IOException("The SSH session is no longer connected.")
                connection = SftpConnection(app, NoAuthentication).also { it.attach(ssh) }
                while (current.images.isNotEmpty()) {
                    val image = current.images.first()
                    val prepared = prepareImage(image.file, image.mimeType, image.source)
                    val name = imageUploadFileName(Instant.now(), prepared.extension)
                    val index = current.uploaded.size
                    val result = connection.uploadImage(
                        current.terminalDirectory, name, prepared.bytes.inputStream(), prepared.bytes.size.toLong(), current.canceled,
                    ) { done, total -> publish(ImageUploadUiState.Running(name, done, total, index, current.total)) }
                    current.uploaded += result.remotePath
                    current.fellBack = current.fellBack || result.fellBackToUploadsFolder
                    current.images.removeAt(0).file.delete()
                }
                val note = if (current.fellBack) {
                    "The current directory could not be used, so images went to ~/$IMAGE_UPLOADS_FOLDER."
                } else null
                main.post {
                    job = null
                    state = ImageUploadUiState.Idle
                    listener?.onImageUploadState(ImageUploadUiState.Idle)
                    val outcome = ImageUploadOutcome(current.sessionId, current.uploaded.toList(), note)
                    listener?.onImageUploadFinished(outcome) ?: run { undelivered = outcome }
                }
            } catch (error: Exception) {
                val message = when {
                    current.canceled.get() && current.liveClient() == null -> "Upload canceled because the SSH session ended."
                    current.canceled.get() -> "Upload canceled."
                    else -> error.message?.takeIf { it.isNotBlank() } ?: "The upload failed."
                }
                if (current.canceled.get()) {
                    main.post {
                        discard(current.images)
                        job = null
                        state = ImageUploadUiState.Failed(message, canRetry = false)
                        listener?.onImageUploadState(state)
                    }
                } else publish(ImageUploadUiState.Failed(message))
            } finally {
                runCatching { connection?.disconnect() }
            }
        }
    }

    private const val MAX_IMAGES_PER_UPLOAD = 10

    private object NoAuthentication : SshAuthenticationCallbacks {
        override fun status(message: String) = Unit
        override fun verifyHostKey(request: HostKeyVerification, answer: (Boolean) -> Unit) = answer(false)
        override fun challenge(challenge: AuthenticationChallenge, answer: (CharArray?) -> Unit): () -> Unit {
            answer(null)
            return {}
        }
    }
}
