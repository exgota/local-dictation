import AppKit
import SwiftUI
import TranscriptHistory

// MARK: History

struct HistorySettingsView: View {
    let context: SettingsContext
    @ObservedObject private var settings: DictationSettings
    @State private var entries: [TranscriptHistoryEntry] = []
    @State private var selection: Int64?
    @State private var correctionEntry: TranscriptHistoryEntry?
    @State private var errorMessage: String?

    init(context: SettingsContext) {
        self.context = context
        settings = context.settings
    }

    var body: some View {
        SettingsPage(width: SettingsLayout.historyWidth, context: context) {
            SectionHeader(title: "History", isFirst: true)
            SettingsRow(label: "Keep history", caption: errorMessage ?? "Stored only on this Mac. Off by default.") {
                HStack(spacing: SettingsLayout.labelControlGap) {
                    Toggle("Keep history", isOn: $settings.configuration.keepsHistory).labelsHidden().toggleStyle(.switch)
                    Spacer(minLength: 0)
                    Button("Delete all", role: .destructive, action: deleteAll).controlSize(.large).disabled(entries.isEmpty)
                }
            }
            SettingsRow(label: "Save as files", caption: "One Markdown file per dictation, in a folder per day. Easy for agents to read.") {
                Toggle("Save as files", isOn: $settings.configuration.transcriptFolder.isEnabled).labelsHidden().toggleStyle(.switch)
            }
            if settings.configuration.transcriptFolder.isEnabled {
                SettingsRow(label: "Folder") {
                    HStack(spacing: SettingsLayout.labelControlGap) {
                        Text((settings.configuration.transcriptFolder.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button("Choose…", action: chooseFolder).controlSize(.large)
                        Button("Show in Finder", action: showFolder).controlSize(.large)
                    }
                }
            }
            GridRow {
                Table(entries, selection: $selection) {
                    TableColumn("Time") { Text($0.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute()) }
                        .width(136)
                    TableColumn("App") { Text($0.applicationName ?? "").lineLimit(1) }.width(112)
                    TableColumn("Text") { Text($0.finalText).lineLimit(2) }.width(min: 160)
                }
                .contextMenu(forSelectionType: Int64.self) { identifiers in
                    if let entry = entries.first(where: { $0.identifier == identifiers.first }) {
                        Button("Copy") { TextInserter.placeOnClipboard(entry.finalText) }
                        Button("Fix this everywhere…") { correctionEntry = entry }
                        Divider()
                        Button("Delete") { delete(entry) }
                    }
                }
                .overlay {
                    if entries.isEmpty {
                        Text(settings.configuration.keepsHistory ? "No dictations yet." : "Turn on Keep history to see dictations here.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 280)
                .gridCellColumns(2)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: settings.configuration.keepsHistory) { _, _ in reload() }
        .sheet(item: $correctionEntry) { entry in
            CorrectionSheet(entry: entry) { heard, canonical in
                do {
                    try context.controller.pipeline.addCorrection(canonical: canonical, mishearing: heard)
                } catch {
                    errorMessage = "The correction could not be saved: \(error.localizedDescription)"
                }
                correctionEntry = nil
            } cancel: {
                correctionEntry = nil
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = settings.configuration.transcriptFolder.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.configuration.transcriptFolder.path = (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func showFolder() {
        let url = settings.configuration.transcriptFolder.url
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func reload() {
        Task {
            guard let store = try? context.controller.pipeline.historyStore() else { return }
            entries = (try? await store.recentEntries(limit: 500)) ?? []
        }
    }

    private func delete(_ entry: TranscriptHistoryEntry) {
        guard let identifier = entry.identifier else { return }
        Task {
            try? await context.controller.pipeline.historyStore().delete(identifier: identifier)
            reload()
        }
    }

    private func deleteAll() {
        Task {
            try? await context.controller.pipeline.historyStore().deleteAll()
            reload()
        }
    }
}

extension TranscriptHistoryEntry: Identifiable {
    public var id: Int64 { identifier ?? 0 }
}

/// "Fix this everywhere": the phrase as the model wrote it and what it should be.
struct CorrectionSheet: View {
    let entry: TranscriptHistoryEntry
    let save: (String, String) -> Void
    let cancel: () -> Void
    @State private var heard = ""
    @State private var canonical = ""

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
            Text("Fix this everywhere").font(.headline)
            Text(entry.finalText).font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: SettingsLayout.labelControlGap, verticalSpacing: SettingsLayout.rowSpacing) {
                GridRow {
                    Text("Heard")
                    TextField("Words as written above", text: $heard)
                }
                GridRow {
                    Text("Should be")
                    TextField("Correct spelling", text: $canonical)
                }
            }
            HStack(spacing: SettingsLayout.labelControlGap) {
                Spacer()
                Button("Cancel", action: cancel).controlSize(.large).keyboardShortcut(.cancelAction)
                Button("Add correction") { save(heard, canonical) }
                    .controlSize(.large).keyboardShortcut(.defaultAction)
                    .disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty || canonical.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(SettingsLayout.windowPadding)
        .frame(width: 400)
    }
}
