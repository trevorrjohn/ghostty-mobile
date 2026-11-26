import SwiftUI
import UIKit

/// Attaches image-upload UI that must work from any screen: the progress chip and the destination and
/// share-in target sheets.
private struct ImageUploadPresentation: ViewModifier {
    @EnvironmentObject private var uploads: ImageUploadCoordinator

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let activity = uploads.activity {
                    ImageUploadChip(activity: activity, retry: uploads.retry, dismiss: uploads.cancelOrDismiss)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: uploads.activity)
            .sheet(item: $uploads.destinationRequest) { request in
                ImageDestinationSheet(request: request)
                    .presentationDetents([.height(340)])
            }
            .sheet(item: $uploads.targetRequest) { request in
                ImageTargetSheet(request: request)
                    .presentationDetents([.medium, .large])
            }
    }
}

extension View {
    func imageUploadPresentation() -> some View { modifier(ImageUploadPresentation()) }
}

struct ImageUploadChip: View {
    let activity: ImageUploadCoordinator.Activity
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let detail { Text(detail).font(.caption).foregroundStyle(Color.ghosttySecondary).lineLimit(2) }
                if activity.phase == .uploading {
                    if let fraction = activity.fraction { ProgressView(value: fraction) }
                    else { ProgressView().progressViewStyle(.linear) }
                }
            }
            Spacer(minLength: 0)
            if case .failed = activity.phase {
                Button("Retry", action: retry).font(.subheadline.weight(.semibold))
            }
            Button(action: dismiss) {
                Image(systemName: activity.phase == .uploading || activity.phase == .preparing ? "xmark.circle.fill" : "xmark")
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel(activity.phase == .uploading || activity.phase == .preparing ? "Cancel upload" : "Dismiss")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var icon: some View {
        switch activity.phase {
        case .preparing, .uploading: Image(systemName: "arrow.up.circle").foregroundStyle(Color.ghosttyAccent)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.ghosttyAccent)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var title: String {
        switch activity.phase {
        case .preparing: activity.fileName
        case .uploading: activity.count > 1 ? "Uploading \(activity.index) of \(activity.count)" : "Uploading image"
        case .done: activity.count > 1 ? "Images uploaded" : "Image uploaded"
        case .failed: "Upload failed"
        }
    }

    private var detail: String? {
        switch activity.phase {
        case .preparing: nil
        case .uploading: activity.fileName
        case .done(let note): note ?? "Path typed into the terminal"
        case .failed(let message): message
        }
    }
}

struct ImageDestinationSheet: View {
    @EnvironmentObject private var uploads: ImageUploadCoordinator
    let request: ImageUploadCoordinator.DestinationRequest
    @State private var remember = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Upload \(request.images.count == 1 ? "image" : "\(request.images.count) images") to \(request.hostName)")
                    .font(.headline)
                Button { uploads.resolve(request, choice: .currentDirectory, remember: remember) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current directory").font(.body.weight(.semibold))
                        Text(request.directory)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.head)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .foregroundStyle(Color.ghosttySurface)
                    .background(Color.ghosttyAccent, in: RoundedRectangle(cornerRadius: 12))
                }
                Button { uploads.resolve(request, choice: .uploadsFolder, remember: remember) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Uploads folder").font(.body.weight(.semibold))
                        Text("~/\(imageUploadsFolder)").font(.system(.caption, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                Toggle("Don't ask again for this host", isOn: $remember).font(.subheadline)
                Spacer(minLength: 0)
            }
            .buttonStyle(.plain)
            .padding(20)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { uploads.cancelDestination(request) }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }
}

struct ImageTargetSheet: View {
    @EnvironmentObject private var uploads: ImageUploadCoordinator
    @EnvironmentObject private var sessions: TerminalSessionRegistry
    @EnvironmentObject private var model: AppModel
    let request: ImageUploadCoordinator.TargetRequest

    var body: some View {
        NavigationStack {
            List {
                let live = sessions.records.filter { $0.session.state == .connected }
                if !live.isEmpty {
                    Section("Active sessions") {
                        ForEach(live) { record in
                            SessionTargetRow(record: record) { uploadsFolder in
                                uploads.choose(session: record, in: request, uploadsFolder: uploadsFolder)
                            }
                        }
                    }
                }
                Section("Saved hosts") {
                    if model.hosts.isEmpty { Text("Save a host first.").foregroundStyle(.secondary) }
                    ForEach(model.hosts) { host in
                        Button { uploads.choose(host: host, in: request) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name)
                                Text("Connect and upload").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Send \(request.images.count == 1 ? "image" : "\(request.images.count) images") to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { uploads.cancelTarget(request) }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

private struct SessionTargetRow: View {
    @ObservedObject var record: TerminalSessionRecord
    let choose: (_ uploadsFolder: Bool) -> Void

    var body: some View {
        let directory = record.session.reportedWorkingDirectory
        VStack(alignment: .leading, spacing: 8) {
            Button { choose(false) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(record.host.name) · \(record.shortID)").font(.body.weight(.semibold))
                    Text(directory ?? "~/\(imageUploadsFolder)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            if directory != nil {
                Button("Use uploads folder instead") { choose(true) }
                    .font(.caption)
            }
        }
        .buttonStyle(.borderless)
    }
}

/// Camera capture. Library selection uses `PhotosPicker`, which needs no permission.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 1) {
                parent.onCapture(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
