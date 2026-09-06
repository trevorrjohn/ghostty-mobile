import SwiftUI

struct HostTrustView: View {
    let request: HostTrustRequest
    let reject: () -> Void
    let accept: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label(
                    request.status == .changed ? "Host key changed" : "Unknown host",
                    systemImage: request.status == .changed ? "exclamationmark.triangle.fill" : "lock.shield"
                )
                .font(.title2.bold())
                .foregroundStyle(request.status == .changed ? Color.red : Color.primary)

                Text(request.status == .changed
                     ? "The saved key does not match. Verify the new fingerprint before replacing trust."
                     : "Verify this fingerprint with the server administrator before trusting it.")

                trustField("Destination", request.destination)
                trustField("Algorithm", request.algorithm)
                trustField("Fingerprint", request.fingerprint)
                if let previousFingerprint = request.previousFingerprint {
                    trustField("Previously trusted", previousFingerprint)
                }
                Spacer()
                Button("Reject", role: .cancel, action: reject)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button(request.status == .changed ? "Replace Saved Key" : "Trust Host", action: accept)
                    .buttonStyle(.borderedProminent)
                    .tint(request.status == .changed ? .red : .accentColor)
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
            .navigationTitle("Verify SSH Host")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
        }
        .presentationDetents([.large])
    }

    private func trustField(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }
}
