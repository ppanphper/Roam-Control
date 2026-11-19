import Foundation

/// Used only for URLs vended by UIDocumentPicker's asCopy delegate. Generic
/// PairingService imports may point at user-owned files and must never use this.
struct PairingPickerCopy {
    let url: URL

    @MainActor
    func use<Result>(temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                     read: (URL) async throws -> Result) async rethrows -> Result? {
        defer { removeFromInbox(temporaryDirectory: temporaryDirectory) }
        guard !Task.isCancelled else { return nil }
        return try await read(url)
    }

    private func removeFromInbox(temporaryDirectory: URL) {
        guard url.isFileURL, temporaryDirectory.isFileURL else { return }
        let scratch = temporaryDirectory.standardizedFileURL
        let resolvedScratch = scratch.resolvingSymlinksInPath()
        let file = url.standardizedFileURL
        let components = file.pathComponents
        // The sandbox itself may have a /var alias. Rebase it before detecting
        // symlinks below tmp so neither a linked file nor a linked Inbox qualifies.
        for root in [scratch, resolvedScratch] {
            let parent = root.pathComponents
            guard components.starts(with: parent), components.count > parent.count + 1,
                  components[parent.count].hasSuffix("-Inbox") else { continue }
            let relative = components.dropFirst(parent.count)
            let candidate = relative.reduce(resolvedScratch) { $0.appendingPathComponent($1) }
            guard candidate.resolvingSymlinksInPath().path == candidate.path,
                  let info = try? candidate.resourceValues(forKeys: [.isRegularFileKey]),
                  info.isRegularFile == true else { return }
            try? FileManager.default.removeItem(at: candidate)
            return
        }
    }
}
