import Photos
import SwiftUI

/// Shown until the app can read the library.
struct AccessView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.openURL) private var openURL

    private var isDenied: Bool {
        library.authorization == .denied || library.authorization == .restricted
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "photo.stack")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 128, height: 128)
                .glassEffect(.regular.tint(.accentColor.opacity(0.18)), in: .circle)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("Make room without losing a thing")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Screenshots, recordings, photos and videos are re-encoded to HEIF and HEVC, right on your iPhone. Dates, places, albums and favorites stay as they are.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 14) {
                point("lock.shield", "Nothing leaves your iPhone. No account, no upload.")
                point("checkmark.seal", "Each copy is checked before its original is touched.")
                point("hand.raised", "iOS asks you before any original is deleted.")
            }
            .font(.subheadline)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))

            Spacer()

            Button {
                if isDenied {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } else {
                    Task { await library.requestAccess() }
                }
            } label: {
                Text(isDenied ? "Open Settings" : "Allow Access to Photos")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)

            if isDenied {
                Text("Photos access is off. Choose Full Access in Settings so every item can be found.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .background(Color.screenBackground.ignoresSafeArea())
    }

    private func point(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
    }
}
