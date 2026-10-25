import SwiftUI

/// Full-screen blurred cover with an unlock button. Asks for Face ID as soon as it appears.
struct LockScreenView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Journal Locked")
                    .font(.title2.weight(.semibold))
                Button {
                    Task { await app.lock.unlock() }
                } label: {
                    Label {
                        Text("Unlock with \(Text(AppLock.biometryName))")
                    } icon: {
                        Image(systemName: "faceid")
                    }
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(app.lock.isAuthenticating)
            }
        }
        .ignoresSafeArea()
        .task(id: scenePhase) {
            if scenePhase == .active { await app.lock.unlock() }
        }
    }
}

/// Shown over the app while it is inactive, so the app switcher never shows entries.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial)
            Image(systemName: "book.closed.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

#Preview {
    LockScreenView()
        .environment(PreviewSupport.model)
}
