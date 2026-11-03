import SwiftUI
import TextProcessing

@MainActor final class CorrectionsDocument: ObservableObject {
    @Published var rows: [VocabularyCorrectionRow] = []
    @Published var errorMessage: String?
    private let fileURL: URL
    private var originalData: Data?
    private var loaded = false

    init(fileURL: URL = ApplicationFiles.vocabularyURL) {
        self.fileURL = fileURL
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                rows = try JSONDecoder().decode(VocabularyCorrections.self, from: data).corrections.map(VocabularyCorrectionRow.init)
                originalData = data
            } else {
                rows = VocabularyCorrections.seed.corrections.map(VocabularyCorrectionRow.init)
            }
            loaded = true
        } catch { errorMessage = "Corrections could not be read. The file has not been changed." }
    }

    func save() -> Bool {
        guard loaded else { return false }
        do {
            let current = FileManager.default.fileExists(atPath: fileURL.path) ? try Data(contentsOf: fileURL) : nil
            guard current == originalData else {
                errorMessage = "Corrections changed in another window. Reopen this sheet before editing."
                return false
            }
            let completed = rows.filter { !$0.canonical.isEmpty || !$0.mishearingsText.isEmpty }
            guard completed.allSatisfy({ !$0.canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                errorMessage = "Enter replacement text for each correction."
                return false
            }
            let corrections = VocabularyCorrections(corrections: completed.map(\.entry))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try corrections.save(to: fileURL)
            originalData = try Data(contentsOf: fileURL)
            return true
        } catch {
            errorMessage = "Corrections could not be saved. Try again."
            return false
        }
    }
}

struct CorrectionsSheet: View {
    @StateObject private var document: CorrectionsDocument
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<UUID> = []
    @FocusState private var focused: UUID?

    init(fileURL: URL = ApplicationFiles.vocabularyURL) {
        _document = StateObject(wrappedValue: CorrectionsDocument(fileURL: fileURL))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Corrections").font(.headline)
            if let error = document.errorMessage { Text(error).foregroundStyle(.secondary) }
            VStack(spacing: 0) {
                Table($document.rows, selection: $selection) {
                    TableColumn("Replace") { $row in
                        TextField("", text: $row.mishearingsText).textFieldStyle(.plain).focused($focused, equals: row.id)
                            .help(row.mishearingsText)
                    }
                    TableColumn("With") { $row in
                        TextField("", text: $row.canonical).textFieldStyle(.plain).help(row.canonical)
                    }
                }
                .tableStyle(.bordered(alternatesRowBackgrounds: true)).frame(height: 194)
                .onDeleteCommand { remove() }
                HStack(spacing: 0) {
                    SettingsAddRemoveControl(removeEnabled: !selection.isEmpty, add: add, remove: remove).fixedSize()
                    Spacer()
                }.padding(.top, 8)
            }
            HStack {
                Spacer()
                if document.errorMessage != nil { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                Button("Done") { if document.save() { dismiss() } }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 460)
    }

    private func add() {
        let row = VocabularyCorrectionRow(.init(canonical: "", mishearings: []))
        document.rows.append(row)
        selection = [row.id]
        DispatchQueue.main.async { focused = row.id }
    }
    private func remove() { document.rows.removeAll { selection.contains($0.id) }; selection = [] }
}

struct AddCorrectionSheet: View {
    let save: (String, String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State var heard: String
    @State private var replacement = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Correction").font(.headline)
            Grid(horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow(alignment: .firstTextBaseline) {
                    Text("Replace:").gridColumnAlignment(.trailing)
                    TextField("", text: $heard)
                }
                GridRow(alignment: .firstTextBaseline) {
                    Text("With:").gridColumnAlignment(.trailing)
                    TextField("", text: $replacement)
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    do { try save(heard, replacement); dismiss() }
                    catch { errorMessage = "The correction could not be saved. Try again." }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty || replacement.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 340)
    }
}
