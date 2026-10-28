import SwiftUI

/// Placeholder for screens that arrive in a later phase.
public struct ComingSoonView: View {
    let title: LocalizedStringResource
    let systemImage: String
    let message: LocalizedStringResource

    public init(title: LocalizedStringResource, systemImage: String, message: LocalizedStringResource) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    public var body: some View {
        ContentUnavailableView {
            Label { Text(title) } icon: { Image(systemName: systemImage) }
        } description: {
            Text(message)
        }
    }
}

#Preview {
    ComingSoonView(title: "Map is coming soon", systemImage: "map", message: "Your entries with a location will show up here as pins.")
}
