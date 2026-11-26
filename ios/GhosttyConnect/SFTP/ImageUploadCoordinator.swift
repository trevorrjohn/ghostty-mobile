import Combine
import Foundation

/// App-level owner of image uploads (ADR 0013): destination prompts, share-in target picking, progress,
/// cancellation and typing the finished path into the terminal. Uploads ride the terminal session's own
/// SSH connection, so there is no second authentication.
@MainActor
final class ImageUploadCoordinator: ObservableObject {
    struct Activity: Identifiable, Equatable {
        enum Phase: Equatable {
            case preparing
            case uploading
            case failed(String)
            case done(note: String?)
        }

        let id = UUID()
        var recordID: UUID?
        var fileName: String
        var index: Int
        var count: Int
        var transferred: UInt64
        var total: UInt64?
        var phase: Phase

        var fraction: Double? {
            guard let total, total > 0 else { return nil }
            return min(1, Double(transferred) / Double(total))
        }
    }

    struct DestinationRequest: Identifiable {
        let id = UUID()
        let recordID: UUID
        let hostID: UUID
        let hostName: String
        let directory: String
        let images: [PreparedImage]
    }

    struct TargetRequest: Identifiable {
        let id = UUID()
        var images: [PreparedImage]
    }

    enum DestinationChoice {
        case currentDirectory
        case uploadsFolder
    }

    private struct Job {
        let images: [PreparedImage]
        let recordID: UUID
        let terminalDirectory: String?
    }

    @Published private(set) var activity: Activity?
    @Published var destinationRequest: DestinationRequest?
    @Published var targetRequest: TargetRequest?
    /// Set when a session should be shown after a share-in; the hosts screen consumes it.
    @Published var requestedSessionID: UUID?

    weak var appModel: AppModel?
    weak var sessions: TerminalSessionRegistry?
    var inbox: ShareInbox? = .shared

    private var lastJob: Job?
    private var uploadTask: Task<Void, Never>?
    private var connectionWaits: [UUID: AnyCancellable] = [:]
    private var handlingBatches: Set<UUID> = []
    private var dismissTask: Task<Void, Never>?

    // MARK: Entry points

    /// Terminal menu: photo library or camera data for one session.
    func submit(data: [Data], source: ImageUploadSource, to record: TerminalSessionRecord) {
        guard !data.isEmpty else { return }
        activity = Activity(recordID: record.id, fileName: "Preparing…", index: 0, count: data.count, transferred: 0, total: nil, phase: .preparing)
        Task { [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) { () -> (images: [PreparedImage], error: String?) in
                var images: [PreparedImage] = []
                var failure: String?
                for item in data {
                    do { images.append(try ImageUploadPreparer.prepare(data: item, source: source)) }
                    catch { failure = error.localizedDescription }
                }
                return (images, failure)
            }.value
            guard let self else { return }
            guard !prepared.images.isEmpty else {
                self.activity = Activity(recordID: record.id, fileName: "Image upload", index: 0, count: data.count, transferred: 0, total: nil,
                                         phase: .failed(prepared.error ?? ImageUploadError.unsupportedImage.localizedDescription))
                return
            }
            self.activity = nil
            self.submit(prepared.images, to: record, source: source, waitForConnection: false)
        }
    }

    /// Chooses between prompting and uploading immediately, from the host's destination setting.
    func submit(_ images: [PreparedImage], to record: TerminalSessionRecord, source: ImageUploadSource, waitForConnection: Bool) {
        guard record.session.state == .connected else {
            if waitForConnection { wait(for: record, images: images, source: source) }
            else { fail(ImageUploadError.notConnected, recordID: record.id, images: images) }
            return
        }
        let mode = resolveImageUploadMode(hostMode: hostMode(for: record), shared: source == .share)
        let directory = record.session.reportedWorkingDirectory
        if shouldPromptForImageDestination(mode: mode, terminalDirectory: directory), let directory {
            destinationRequest = DestinationRequest(
                recordID: record.id,
                hostID: record.host.id,
                hostName: record.host.name,
                directory: directory,
                images: images
            )
        } else {
            start(Job(images: images, recordID: record.id, terminalDirectory: imageUploadTerminalDirectory(mode: mode, terminalDirectory: directory)))
        }
    }

    func resolve(_ request: DestinationRequest, choice: DestinationChoice, remember: Bool) {
        destinationRequest = nil
        if remember, let appModel, var host = appModel.hosts.first(where: { $0.id == request.hostID }) {
            host.imageUploadMode = choice == .currentDirectory ? .currentDirectory : .uploadsFolder
            appModel.save(host: host)
        }
        start(Job(images: request.images, recordID: request.recordID, terminalDirectory: choice == .currentDirectory ? request.directory : nil))
    }

    func cancelDestination(_ request: DestinationRequest) {
        destinationRequest = nil
        ImageUploadPreparer.discard(request.images)
    }

    // MARK: Share-in

    /// Collects images the Share extension left in the App Group inbox. Safe to call repeatedly.
    func receiveSharedImages(batchID: UUID? = nil) {
        guard let inbox else {
            if batchID != nil { appModel?.alertMessage = "Sharing isn't set up for this build of Seance Shell." }
            return
        }
        inbox.purgeStale()
        let ids = (batchID.map { [$0] } ?? []) + inbox.pendingBatchIDs().filter { $0 != batchID }
        for id in ids where !handlingBatches.contains(id) && !inbox.files(in: id).isEmpty {
            handlingBatches.insert(id)
            let files = inbox.files(in: id)
            Task { [weak self] in
                let images = await Task.detached(priority: .userInitiated) {
                    files.compactMap { try? ImageUploadPreparer.prepare(fileAt: $0, source: .share) }
                }.value
                inbox.remove(id)
                guard let self else { return }
                self.handlingBatches.remove(id)
                if images.isEmpty { self.appModel?.alertMessage = ImageUploadError.unsupportedImage.localizedDescription }
                else { self.routeShared(images) }
            }
        }
    }

    private func routeShared(_ images: [PreparedImage]) {
        let live = (sessions?.records ?? []).filter { $0.session.state == .connected }
        if shareInGoesToSingleSession(liveSessionCount: live.count), let record = live.first {
            requestedSessionID = record.id
            submit(images, to: record, source: .share, waitForConnection: false)
        } else if var request = targetRequest {
            request.images += images
            targetRequest = request
        } else {
            targetRequest = TargetRequest(images: images)
        }
    }

    /// The row tap is the destination choice: the session's current directory, or the uploads folder.
    func choose(session record: TerminalSessionRecord, in request: TargetRequest, uploadsFolder: Bool) {
        targetRequest = nil
        requestedSessionID = record.id
        guard record.session.state == .connected else {
            return fail(ImageUploadError.notConnected, recordID: record.id, images: request.images)
        }
        let useUploads = uploadsFolder || hostMode(for: record) == .uploadsFolder
        start(Job(
            images: request.images,
            recordID: record.id,
            terminalDirectory: useUploads ? nil : record.session.reportedWorkingDirectory
        ))
    }

    /// A saved host with no live session: open a terminal through the normal trust and authentication
    /// flow, then upload once it connects.
    func choose(host: Host, in request: TargetRequest) {
        targetRequest = nil
        guard let sessions else { return ImageUploadPreparer.discard(request.images) }
        let record = sessions.record(id: sessions.create(for: host))!
        requestedSessionID = record.id
        wait(for: record, images: request.images, source: .share)
    }

    func cancelTarget(_ request: TargetRequest) {
        targetRequest = nil
        ImageUploadPreparer.discard(request.images)
    }

    // MARK: Activity

    func retry() {
        guard let lastJob else { return }
        start(lastJob)
    }

    /// Cancels a running upload, or dismisses a finished or failed one.
    func cancelOrDismiss() {
        dismissTask?.cancel()
        uploadTask?.cancel()
        uploadTask = nil
        if let lastJob { ImageUploadPreparer.discard(lastJob.images) }
        lastJob = nil
        activity = nil
    }

    // MARK: Upload

    private func hostMode(for record: TerminalSessionRecord) -> ImageUploadDestinationMode? {
        appModel?.hosts.first { $0.id == record.host.id }?.imageUploadMode ?? record.host.imageUploadMode
    }

    private func wait(for record: TerminalSessionRecord, images: [PreparedImage], source: ImageUploadSource) {
        let id = record.id
        activity = Activity(recordID: id, fileName: "Waiting for \(record.host.name)…", index: 0, count: images.count, transferred: 0, total: nil, phase: .preparing)
        connectionWaits[id] = record.session.$state.sink { [weak self, weak record] state in
            guard let self else { return }
            guard let record, self.sessions?.record(id: id) != nil else { return self.abandonWait(id, images: images) }
            switch state {
            case .connected:
                self.connectionWaits[id] = nil
                self.activity = nil
                // Give the new shell a moment to report its directory before choosing a destination.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(800))
                    self?.submit(images, to: record, source: source, waitForConnection: false)
                }
            case .failed:
                self.abandonWait(id, images: images)
                self.fail(ImageUploadError.notConnected, recordID: id, images: nil)
            default:
                break
            }
        }
    }

    private func abandonWait(_ id: UUID, images: [PreparedImage]) {
        connectionWaits[id] = nil
        activity = nil
        ImageUploadPreparer.discard(images)
    }

    private func fail(_ error: Error, recordID: UUID, images: [PreparedImage]?) {
        if let images { ImageUploadPreparer.discard(images) }
        activity = Activity(recordID: recordID, fileName: "Image upload", index: 0, count: 0, transferred: 0, total: nil, phase: .failed(error.localizedDescription))
    }

    private func start(_ job: Job) {
        dismissTask?.cancel()
        uploadTask?.cancel()
        lastJob = job
        guard let record = sessions?.record(id: job.recordID) else {
            return fail(ImageUploadError.notConnected, recordID: job.recordID, images: job.images)
        }
        activity = Activity(recordID: job.recordID, fileName: "Uploading…", index: 1, count: job.images.count, transferred: 0, total: nil, phase: .uploading)
        uploadTask = Task { [weak self] in await self?.perform(job, record: record) }
    }

    private func perform(_ job: Job, record: TerminalSessionRecord) async {
        var channel: (any RemoteImageFiles)?
        do {
            let files = try await record.session.openRemoteImageFiles()
            channel = files
            let totalBytes = job.images.reduce(UInt64(0)) { $0 + UInt64($1.byteCount) }
            var terminalDirectory = job.terminalDirectory
            var sent: UInt64 = 0
            var results: [ImageUploadResult] = []
            for (offset, image) in job.images.enumerated() {
                try Task.checkCancellation()
                let name = imageUploadFileName(now: Date(), fileExtension: image.fileExtension)
                update(fileName: name, index: offset + 1, transferred: sent, total: totalBytes)
                let base = sent
                let result = try await ImageUploader.upload(
                    files: files,
                    terminalDirectory: terminalDirectory,
                    fileName: name,
                    from: image.url
                ) { [weak self] done, _ in
                    Task { @MainActor in self?.update(transferred: base + done) }
                }
                if result.fellBackToUploadsFolder { terminalDirectory = nil }
                results.append(result)
                sent += UInt64(image.byteCount)
            }
            await files.close()
            channel = nil
            record.session.paste(pastedUploadPaths(results.map(\.remotePath)))
            ImageUploadPreparer.discard(job.images)
            lastJob = nil
            let fellBack = results.contains { $0.fellBackToUploadsFolder }
            activity?.phase = .done(note: fellBack ? "Uploaded to ~/\(imageUploadsFolder) (current directory not writable)" : nil)
            activity?.transferred = totalBytes
            scheduleDismissal()
        } catch is CancellationError {
            await channel?.close()
        } catch {
            await channel?.close()
            activity?.phase = .failed(CitadelRemoteImageFiles.failureDescription(error))
        }
    }

    private func update(fileName: String? = nil, index: Int? = nil, transferred: UInt64, total: UInt64? = nil) {
        guard activity?.phase == .uploading else { return }
        if let fileName { activity?.fileName = fileName }
        if let index { activity?.index = index }
        if let total { activity?.total = total }
        if let current = activity?.transferred, transferred < current, index == nil { return }
        activity?.transferred = transferred
    }

    private func update(transferred: UInt64) {
        update(fileName: nil, index: nil, transferred: transferred)
    }

    private func scheduleDismissal() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.activity = nil
        }
    }
}
