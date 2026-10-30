import AppKit
import DictationEngine
import SwiftUI

// MARK: About

struct AboutSettingsView: View {
    let context: SettingsContext
    @State private var showsDeveloperTools = NSEvent.modifierFlags.contains(.option)
    @State private var modifierMonitor: Any?

    var body: some View {
        SettingsPage(width: SettingsLayout.standardWidth) {
            SectionHeader(title: "Local Dictation", isFirst: true)
            SettingsRow(label: "Version", caption: "Speech recognition runs on this Mac. Nothing is uploaded.") {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
            }

            SectionHeader(title: "Credits")
            attribution("Speech model", "Underdog Bark 3.0 Pro, CC BY 4.0", "https://huggingface.co/\(ModelManifest.repository)")
            SettingsRow(label: "Licenses", caption: "Parakeet (NVIDIA, Moondream), Silero VAD and FluidAudio.") {
                Button("Show licenses") { Self.showLicenses() }.controlSize(.large)
            }

            if showsDeveloperTools {
                SectionHeader(title: "Developer")
                SettingsRow(label: "Fixtures", caption: "Records the twelve test takes used by --selftest.") {
                    Button("Record fixture…") { FixtureRecorderWindowController.shared.show(context: context) }.controlSize(.large)
                }
            }
        }
        .onAppear {
            modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                if event.modifierFlags.contains(.option) { showsDeveloperTools = true }
                return event
            }
        }
        .onDisappear {
            if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
            modifierMonitor = nil
        }
    }

    /// Opens the bundled NOTICE file in the default text editor rather than in whatever opens plain files by extension.
    @MainActor static func showLicenses() {
        guard let notice = Bundle.main.url(forResource: "NOTICE", withExtension: nil) else { return }
        TextEditorLauncher.open(notice)
    }

    private func attribution(_ name: String, _ detail: String, _ link: String) -> some View {
        SettingsRow(label: name) {
            HStack(alignment: .firstTextBaseline, spacing: SettingsLayout.labelControlGap) {
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let url = URL(string: link) { Link("Source", destination: url) }
            }
        }
    }
}
