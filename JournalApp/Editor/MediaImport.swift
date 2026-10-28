import AVFoundation
import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A photo or video from the Photos picker, copied to a temporary file in its original format
/// (HEIC stays HEIC). `MediaStorage` then moves it into the journal.
nonisolated struct PickedMediaFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try PickedMediaFile(url: copyToTemporary(received.file))
        }
        FileRepresentation(importedContentType: .image) { received in
            try PickedMediaFile(url: copyToTemporary(received.file))
        }
    }

    /// The picker deletes its file after this closure returns, so keep a copy.
    private static func copyToTemporary(_ file: URL) throws -> URL {
        let ext = file.pathExtension.isEmpty ? "dat" : file.pathExtension
        let destination = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }
}

/// The system camera, for taking a photo straight into an entry.
// DECISION: photos only for now; video capture from the camera can come with Phase 2 media work.
struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onCapture(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    /// Asks for camera access when needed. Returns false if the user has said no.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}

/// Opens this app's page in the Settings app, for permissions the user turned off.
@MainActor
func openAppSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
    }
}
