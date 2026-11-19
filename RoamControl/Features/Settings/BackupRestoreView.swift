import SwiftUI
import UniformTypeIdentifiers

struct BackupRestoreView: View {
    @Environment(\.appLocalization) private var l10n
    @Environment(AppModel.self) private var appModel
    @State private var selectingFile = false
    @State private var pendingBackup: AppBackup?
    @State private var errorMessage: String?
    @State private var exportURL: URL?
    @State private var restored = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Favourites", value: "\(appModel.favouriteLocations.count)")
                LabeledContent("History", value: "\(appModel.locationHistory.count)")
                Button("Create Backup", systemImage: "square.and.arrow.up") { createBackup() }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Save or Share Backup", systemImage: "doc.badge.arrow.up")
                    }
                }
                Button("Restore Backup", systemImage: "square.and.arrow.down") { selectingFile = true }
            } footer: {
                Text("Includes favourites, history and preferences. Saved names and coordinates are in the file. Pairing keys, active sessions and statistics identity are excluded.")
            }
            if let backup = pendingBackup {
                Section("Review Backup") {
                    LabeledContent("Created", value: backup.createdAt.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(l10n.locale)))
                    LabeledContent("Favourites", value: "\(backup.favourites.count)")
                    LabeledContent("History", value: "\(backup.history.count)")
                    Text("Restoring replaces saved places and supported preferences on this installation.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Replace with This Backup", role: .destructive) {
                        do {
                            try appModel.restoreBackup(backup)
                            pendingBackup = nil
                            restored = true
                        } catch { errorMessage = error.localizedDescription }
                    }
                    Button("Cancel", role: .cancel) { pendingBackup = nil }
                }
            }
            if restored { Label("Backup Restored", systemImage: "checkmark.circle") }
        }
        .navigationTitle(Text(verbatim: l10n.text("Backup & Restore")))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $selectingFile) {
            BackupDocumentPicker { result in
                selectingFile = false
                switch result {
                case .success(let url):
                    guard let url else { return }
                    pendingBackup = nil
                    restored = false
                    do {
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= BackupService.byteLimit else { throw BackupError.tooLarge }
                        pendingBackup = try BackupService.decode(Data(contentsOf: url, options: .mappedIfSafe))
                        restored = false
                    } catch { errorMessage = error.localizedDescription }
                case .failure(let error):
                    pendingBackup = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
        .alert("Backup Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(verbatim: l10n.text(errorMessage ?? "Please try again.")) }
    }

    private func createBackup() {
        do {
            let data = try BackupService.encode(appModel.makeBackup())
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RoamBackups", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
            let url = folder.appendingPathComponent("Roam-Control-\(stamp).json")
            try data.write(to: url, options: .atomic)
            exportURL = url
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct BackupDocumentPicker: UIViewControllerRepresentable {
    let completion: (Result<URL?, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .data], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Result<URL?, Error>) -> Void
        init(completion: @escaping (Result<URL?, Error>) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completion(.success(urls.first))
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(.success(nil)) }
    }
}
