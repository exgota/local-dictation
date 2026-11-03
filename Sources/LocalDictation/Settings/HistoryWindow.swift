import AppKit
import SwiftUI
import TranscriptHistory

@MainActor final class HistoryWindowController: NSWindowController {
    init(pipeline: TranscriptPipeline) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: HistoryView(pipeline: pipeline)))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "History"
        window.setContentSize(NSSize(width: 660, height: 470))
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func show() {
        if window?.isVisible != true { window?.center() }
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HistoryView: View {
    @ObservedObject var pipeline: TranscriptPipeline
    @State var entries: [TranscriptHistoryEntry] = []
    var loadsArchive = true
    @State var selection: Int64?
    @State private var selectedText = ""
    @State private var addsCorrection = false
    @State private var confirmsClear = false
    @State private var errorMessage: String?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdjm")
        return formatter
    }()

    private var selected: TranscriptHistoryEntry? { entries.first { $0.identifier == selection } }

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                Text("No Dictations").font(.title3).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VSplitView {
                    List(entries, id: \.identifier, selection: $selection) { entry in
                        HStack(spacing: 12) {
                            Text(entry.finalText).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(entry.applicationName ?? "").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                            Text(Self.dateFormatter.string(from: entry.timestamp))
                                .foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
                        }
                        .listRowSeparator(.hidden).tag(entry.identifier ?? 0)
                    }
                    .listStyle(.inset).alternatingRowBackgrounds(.disabled)
                    .frame(minHeight: 140, idealHeight: 226)
                    .onDeleteCommand { deleteSelected() }
                    detail.frame(minHeight: 120, idealHeight: 150)
                }
            }
            HStack {
                Button("Clear History…") { confirmsClear = true }.disabled(entries.isEmpty)
                Spacer()
                if !entries.isEmpty { Text(entries.count == 1 ? "1 dictation" : "\(entries.count) dictations").foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
        }
        .frame(minWidth: 520, minHeight: 360)
        .task { if loadsArchive { await reload(selectFirst: true) } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if loadsArchive { Task { await reload() } }
        }
        .onChange(of: pipeline.historyRevision) { _, _ in Task { await reload() } }
        .onChange(of: selection) { _, _ in selectedText = "" }
        .sheet(isPresented: $addsCorrection) {
            AddCorrectionSheet(save: { heard, replacement in try pipeline.addCorrection(canonical: replacement, mishearing: heard) }, heard: selectedText)
        }
        .alert("Clear all dictations?", isPresented: $confirmsClear) {
            Button("Clear History", role: .destructive) {
                Task {
                    do { try await pipeline.historyStore().deleteAll(); selection = nil; await reload() }
                    catch { errorMessage = "History could not be cleared. Try again." }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This can’t be undone.") }
        .alert("History", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder private var detail: some View {
        if let selected {
            VStack(alignment: .leading, spacing: 10) {
                HistorySelectableText(text: selected.finalText, identity: selected.identifier, selection: $selectedText).frame(maxHeight: .infinity)
                HStack(spacing: 8) {
                    Spacer()
                    Button("Add Correction…") { addsCorrection = true }
                    Button("Copy") { TextInserter.placeOnClipboard(selectedText.isEmpty ? selected.finalText : selectedText) }.keyboardShortcut("c")
                }
            }.padding(16)
        } else {
            Text("No Selection").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func reload(selectFirst: Bool = false) async {
        guard loadsArchive else { return }
        do {
            entries = try await pipeline.historyStore().recentEntries(limit: Int.max)
            if selectFirst && selection == nil { selection = entries.first?.identifier }
            if let selection, !entries.contains(where: { $0.identifier == selection }) { self.selection = nil }
        } catch { errorMessage = "History could not be read. Try again." }
    }

    private func deleteSelected() {
        guard let selection else { return }
        Task {
            do { try await pipeline.historyStore().delete(identifier: selection); self.selection = nil; await reload() }
            catch { errorMessage = "The dictation could not be deleted. Try again." }
        }
    }
}
