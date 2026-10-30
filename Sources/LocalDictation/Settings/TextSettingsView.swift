import AppKit
import SwiftUI
import TextProcessing
import UniformTypeIdentifiers

// MARK: Text

struct TextSettingsView: View {
    let context: SettingsContext
    @ObservedObject private var settings: DictationSettings

    init(context: SettingsContext) {
        self.context = context
        settings = context.settings
    }

    var body: some View {
        SettingsPage(width: SettingsLayout.textWidth, context: context) {
            SectionHeader(title: "Formatting", isFirst: true)
            SettingsRow(label: "Default style", caption: styleCaption(settings.configuration.profiles.defaultProfile)) {
                profilePicker($settings.configuration.profiles.defaultProfile, includesSuppressed: false)
            }
            SettingsRow(label: "App styles", caption: "Chat apps tidy text, terminals and editors stay verbatim, password managers get nothing.") {
                VStack(alignment: .leading, spacing: SettingsLayout.labelControlGap) {
                    ForEach(settings.configuration.profiles.overrides.keys.sorted(), id: \.self) { bundleIdentifier in
                        HStack(spacing: SettingsLayout.labelControlGap) {
                            Text(Self.applicationName(bundleIdentifier)).frame(width: 140, alignment: .leading).lineLimit(1)
                            profilePicker(overrideBinding(bundleIdentifier), includesSuppressed: true)
                            Button("Remove") { settings.configuration.profiles.overrides[bundleIdentifier] = nil }.controlSize(.large)
                        }
                    }
                    Button("Add app…", action: addApplication).controlSize(.large)
                }
            }
            SettingsRow(label: "Chat apps", caption: "Presses Return after inserting, which sends the message. Off by default.") {
                Toggle("Send in chat apps", isOn: $settings.configuration.chatSubmitsWithReturn).labelsHidden().toggleStyle(.switch)
            }

            SectionHeader(title: "Vocabulary")
            SettingsRow(label: "Corrections", caption: "Fixes names the model mishears, such as Claude Code and CLAUDE.md.") {
                HStack(spacing: SettingsLayout.labelControlGap) {
                    Toggle("Corrections", isOn: $settings.configuration.vocabularyCorrectionsEnabled).labelsHidden().toggleStyle(.switch)
                    Button("Edit vocabulary") { Self.openVocabulary(context) }.controlSize(.large)
                }
            }
        }
    }

    private func styleCaption(_ profile: TranscriptProfile) -> String {
        switch profile {
        case .verbatim: return "Exactly what you said, fillers included."
        case .chat: return "Removes fillers, applies spoken punctuation and capitalizes."
        case .code: return "Exactly what you said. Never presses Return."
        case .suppressed: return "Nothing is inserted."
        }
    }

    private func profilePicker(_ selection: Binding<TranscriptProfile>, includesSuppressed: Bool) -> some View {
        Picker("Style", selection: selection) {
            ForEach(TranscriptProfile.allCases.filter { includesSuppressed || $0 != .suppressed }, id: \.self) {
                Text($0.displayName).tag($0)
            }
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
    }

    private func overrideBinding(_ bundleIdentifier: String) -> Binding<TranscriptProfile> {
        Binding(
            get: { settings.configuration.profiles.overrides[bundleIdentifier] ?? .verbatim },
            set: { settings.configuration.profiles.overrides[bundleIdentifier] = $0 })
    }

    private func addApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url, let identifier = Bundle(url: url)?.bundleIdentifier else { return }
        settings.configuration.profiles.overrides[identifier] = settings.configuration.profiles.profile(forBundleIdentifier: identifier)
    }

    static func applicationName(_ bundleIdentifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return bundleIdentifier }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    @MainActor static func openVocabulary(_ context: SettingsContext) {
        // Creates the file from the seed only if it is missing; an existing file is opened as it is.
        _ = try? context.controller.pipeline.loadVocabulary()
        TextEditorLauncher.open(ApplicationFiles.vocabularyURL)
    }
}
