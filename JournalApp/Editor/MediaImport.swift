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

/// A file picked in the Files app, copied out before the picker's access ends.
enum PickedFile {
    /// Copies the file to a temporary folder, downloading it first if it's in iCloud Drive
    /// and not on the device yet.
    @concurrent nonisolated static func copyToTemporary(_ url: URL) async throws -> URL {
        // Files from other apps' folders and iCloud Drive need permission to read.
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: url.lastPathComponent)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            do {
                try FileManager.default.copyItem(at: readableURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
        return destination
    }
}

/// What the camera captured.
enum CameraCapture {
    case photo(Data)
    /// A movie, already copied to a temporary file.
    case video(URL)
}

/// The system camera, for taking a photo or video straight into an entry.
struct CameraPicker: UIViewControllerRepresentable {
    var onCapture: (CameraCapture) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        let available = UIImagePickerController.availableMediaTypes(for: .camera) ?? [UTType.image.identifier]
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier].filter { available.contains($0) }
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let movie = info[.mediaURL] as? URL {
                // The picker deletes its file when it closes, so keep a copy.
                let copy = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).\(movie.pathExtension.isEmpty ? "mov" : movie.pathExtension)")
                if (try? FileManager.default.copyItem(at: movie, to: copy)) != nil {
                    parent.onCapture(.video(copy))
                }
            } else if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onCapture(.photo(data))
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
