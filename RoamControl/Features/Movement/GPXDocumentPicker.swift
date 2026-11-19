import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct GPXDocumentPicker: UIViewControllerRepresentable {
    enum Mode: Identifiable {
        case open
        case save(URL)

        var id: String {
            switch self {
            case .open: "open"
            case .save(let url): url.path
            }
        }
    }

    let mode: Mode
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker: UIDocumentPickerViewController
        switch mode {
        case .open:
            // Some providers advertise GPX as generic data. Validate the copy in GPXService.
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        case .save(let url):
            picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        }
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIViewController(_ controller: UIDocumentPickerViewController, coordinator: Coordinator) {
        if case .save(let url) = coordinator.parent.mode {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: GPXDocumentPicker
        init(parent: GPXDocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { parent.onPick(url) } else { parent.onCancel() }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
