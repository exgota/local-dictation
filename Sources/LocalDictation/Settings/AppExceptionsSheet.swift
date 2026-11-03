import AppKit
import SwiftUI
import TextProcessing
import UniformTypeIdentifiers

struct AppExceptionEntry: Identifiable {
    let id: String
    let name: String
    let url: URL?
    let builtIn: Bool

    @MainActor static func entries(for profiles: ProfileResolver) -> [Self] {
        var identifiers: [String: String] = [:]
        for identifier in ProfileResolver.builtInProfiles.keys { identifiers[identifier.lowercased()] = identifier }
        for identifier in profiles.overrides.keys { identifiers[identifier.lowercased()] = identifier }
        return identifiers.values.compactMap { identifier -> Self? in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
            let hasOverride = profiles.overrides.keys.contains { $0.caseInsensitiveCompare(identifier) == .orderedSame }
            guard url != nil || hasOverride else { return nil }
            let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                ?? applicationNames[identifier.lowercased()] ?? identifier
            return Self(id: identifier, name: name, url: url,
                        builtIn: ProfileResolver.builtInProfiles.keys.contains { $0.caseInsensitiveCompare(identifier) == .orderedSame })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static let applicationNames = [
        "com.1password.1password": "1Password", "com.agilebits.onepassword7": "1Password 7",
        "com.bitwarden.desktop": "Bitwarden", "com.apple.passwords": "Passwords", "com.dashlane.dashlane": "Dashlane",
        "com.lastpass.lastpass": "LastPass", "org.keepassxc.keepassxc": "KeePassXC", "com.apple.terminal": "Terminal",
        "com.googlecode.iterm2": "iTerm", "dev.warp.warp-stable": "Warp", "com.mitchellh.ghostty": "Ghostty",
        "com.microsoft.vscode": "Visual Studio Code", "com.apple.dt.xcode": "Xcode",
        "com.todesktop.230313mzl4w4u92": "Cursor", "dev.zed.zed": "Zed", "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.discord": "Discord", "ru.keepcoder.telegram": "Telegram", "net.whatsapp.whatsapp": "WhatsApp",
        "com.apple.mobilesms": "Messages",
    ]
}

struct AppExceptionsSheet: View {
    @ObservedObject var settings: DictationSettings
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    private var entries: [AppExceptionEntry] { AppExceptionEntry.entries(for: settings.configuration.profiles) }
    private var removable: Bool { entries.first { $0.id == selection }.map { !$0.builtIn } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App Exceptions").font(.headline)
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(entries) { entry in
                        HStack(spacing: 8) {
                            Image(nsImage: entry.url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                                  ?? NSImage(systemSymbolName: "app", accessibilityDescription: "Application unavailable")!).resizable().frame(width: 20, height: 20)
                            Text(entry.name)
                            Spacer()
                            SettingsPopUpButton(items: ["Unformatted", "Formatted", "-", "Do Not Insert"],
                                                selection: profileBinding(entry.id), width: 146)
                        }
                        .padding(.vertical, 2).listRowSeparator(.hidden).tag(entry.id)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true)).frame(height: 194)
                .onDeleteCommand { remove() }
                HStack(spacing: 0) {
                    SettingsAddRemoveControl(removeEnabled: removable, add: add, remove: remove).fixedSize()
                    Spacer()
                }.padding(.top, 8)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 460)
    }

    private func profileBinding(_ identifier: String) -> Binding<Int> {
        Binding(get: {
            switch settings.configuration.profiles.profile(forBundleIdentifier: identifier) {
            case .verbatim, .code: 0
            case .chat: 1
            case .suppressed: 3
            }
        }, set: { index in
            for key in settings.configuration.profiles.overrides.keys where key.caseInsensitiveCompare(identifier) == .orderedSame {
                settings.configuration.profiles.overrides[key] = nil
            }
            settings.configuration.profiles.overrides[identifier] = index == 3 ? .suppressed : index == 1 ? .chat : .verbatim
        })
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url, let identifier = Bundle(url: url)?.bundleIdentifier else { return }
        if let entry = entries.first(where: { $0.id.caseInsensitiveCompare(identifier) == .orderedSame }) { selection = entry.id; return }
        settings.configuration.profiles.overrides[identifier] = settings.configuration.profiles.profile(forBundleIdentifier: identifier)
        selection = identifier
    }

    private func remove() {
        guard removable, let selection else { return }
        settings.configuration.profiles.overrides[selection] = nil
        self.selection = nil
    }
}
