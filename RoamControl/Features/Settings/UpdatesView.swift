import SwiftUI

struct UpdatesView: View {
    @Environment(\.appLocalization) private var l10n
    @Environment(AppModel.self) private var appModel
    var body: some View {
        @Bindable var preferences = appModel.featurePreferences
        Form {
            Section {
                Toggle("Check Automatically", isOn: $preferences.automaticUpdateChecks)
                Button {
                    Task { await appModel.releaseUpdates.check() }
                } label: {
                    HStack {
                        Text("Check for Updates")
                        Spacer()
                        if appModel.releaseUpdates.state == .checking { ProgressView() }
                    }
                }
                .disabled(appModel.releaseUpdates.state == .checking)
            } footer: {
                Text("Checks this personal fork's public GitHub releases. No app is downloaded or installed automatically.")
            }
            Section {
                switch appModel.releaseUpdates.state {
                case .idle: EmptyView()
                case .checking: Text("Checking…")
                case .current: Label("You're Up to Date", systemImage: "checkmark.circle")
                case .noPublishedRelease: Text("This fork has no published stable release yet.")
                case .failed(let message): Text(verbatim: l10n.text(message)).foregroundStyle(.red)
                case .available(let release):
                    LabeledContent("Available Version", value: l10n.technical(release.tag_name))
                    if let notes = release.body, !notes.isEmpty { Text(notes).font(.footnote).textSelection(.enabled) }
                    Link("View Release", destination: release.html_url)
                    Button("Dismiss This Version") { appModel.releaseUpdates.dismiss(release) }
                }
            }
            Section("Source") { Text(verbatim: l10n.technical(ReleaseUpdateService.repository)).font(.footnote).textSelection(.enabled) }
        }
        .navigationTitle(Text(verbatim: l10n.text("Updates")))
        .navigationBarTitleDisplayMode(.inline)
    }
}
