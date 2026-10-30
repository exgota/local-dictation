import AppKit
import DictationCore
import DictationEngine
import ServiceManagement
import SwiftUI
import TextProcessing
import TranscriptHistory
import UniformTypeIdentifiers

/// The spacing scale and sizes that the settings views share.
enum SettingsLayout {
    static let windowPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 24
    static let rowSpacing: CGFloat = 12
    static let labelControlGap: CGFloat = 8
    static let captionGap: CGFloat = 4
    static let standardWidth: CGFloat = 480
    static let textWidth: CGFloat = 520
    static let historyWidth: CGFloat = 560
    static let minimumRowHeight: CGFloat = 24
}

enum SettingsTab: String, CaseIterable {
    case general, hotkey, audio, text, history, about

    var title: String {
        switch self {
        case .general: return "General"
        case .hotkey: return "Hotkey"
        case .audio: return "Audio"
        case .text: return "Text"
        case .history: return "History"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .hotkey: return "keyboard"
        case .audio: return "mic"
        case .text: return "text.alignleft"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }
}

/// Everything the settings views read and change.
@MainActor struct SettingsContext {
    let settings: DictationSettings
    let permissions: PermissionMonitor
    let model: ModelController
    let controller: DictationController
}

/// A standard macOS preferences window: toolbar tabs, each sized to its content, resizing as tabs change.
@MainActor final class SettingsWindowController: NSWindowController {
    private let tabController = NSTabViewController()

    init(context: SettingsContext) {
        tabController.tabStyle = .toolbar
        tabController.transitionOptions = [.allowUserInteraction]
        for tab in SettingsTab.allCases {
            let hosting = NSHostingController(rootView: AnyView(Self.view(for: tab, context: context)))
            hosting.sizingOptions = [.preferredContentSize]
            hosting.title = tab.title
            let item = NSTabViewItem(viewController: hosting)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            item.identifier = tab.rawValue
            tabController.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabController)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.title = SettingsTab.general.title
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ tab: SettingsTab? = nil) {
        if let tab, let index = SettingsTab.allCases.firstIndex(of: tab) { tabController.selectedTabViewItemIndex = index }
        if window?.isVisible != true, let window {
            let screen = HeadsUpDisplayController.screenWithMouse()
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.maxY - window.frame.height - 120))
        }
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private static func view(for tab: SettingsTab, context: SettingsContext) -> any View {
        switch tab {
        case .general: return GeneralSettingsView(context: context)
        case .hotkey: return HotkeySettingsView(context: context)
        case .audio: return AudioSettingsView(context: context)
        case .text: return TextSettingsView(context: context)
        case .history: return HistorySettingsView(context: context)
        case .about: return AboutSettingsView(context: context)
        }
    }
}

// MARK: Layout components

/// A settings page: banners, then one grid so labels and controls line up across all sections.
struct SettingsPage<Content: View>: View {
    let width: CGFloat
    var banners: [InlineBanner.Content] = []
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            ForEach(banners) { InlineBanner(content: $0) }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: SettingsLayout.labelControlGap, verticalSpacing: SettingsLayout.rowSpacing) {
                content
            }
        }
        .padding(SettingsLayout.windowPadding)
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A section title spanning both columns. Every section after the first adds 12 pt to the 12 pt row spacing, for 24.
struct SectionHeader: View {
    let title: String
    var isFirst = false

    var body: some View {
        GridRow {
            Text(title).font(.headline).gridCellColumns(2)
        }
        .padding(.top, isFirst ? 0 : SettingsLayout.sectionSpacing - SettingsLayout.rowSpacing)
    }
}

/// A row: a left-aligned label column and a left-aligned control column, with an optional caption under the control.
struct SettingsRow<Control: View>: View {
    let label: String
    var caption: String?
    @ViewBuilder let control: Control

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).gridColumnAlignment(.leading)
            VStack(alignment: .leading, spacing: SettingsLayout.captionGap) {
                control.frame(minHeight: SettingsLayout.minimumRowHeight)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .gridColumnAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A symbol and a word: the status of a permission or component.
struct StatusIndicator: View {
    let isOK: Bool
    let okText: String
    let problemText: String

    var body: some View {
        HStack(spacing: SettingsLayout.labelControlGap) {
            Image(systemName: isOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isOK ? Color.accentColor : Color.secondary)
            Text(isOK ? okText : problemText)
        }
    }
}

/// An inline banner at the top of a page for a condition that needs the user, instead of an alert.
struct InlineBanner: View {
    struct Content: Identifiable {
        let id: String
        let message: String
        var actionTitle: String?
        var action: (() -> Void)?
    }

    let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsLayout.labelControlGap) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.accentColor)
            Text(content.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let title = content.actionTitle, let action = content.action {
                Button(title, action: action).controlSize(.large)
            }
        }
        .padding(SettingsLayout.rowSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Banners shared by every page except About: permissions, installation, settings file and secure input.
@MainActor func commonBanners(_ context: SettingsContext) -> [InlineBanner.Content] {
    var banners: [InlineBanner.Content] = []
    if !context.permissions.allGranted {
        banners.append(InlineBanner.Content(
            id: "permissions", message: "Dictation needs Microphone and Accessibility access.", actionTitle: "Open setup",
            action: { context.controller.onRequiresAttention() }))
    }
    for (index, warning) in InstallationCheck.current().warnings.enumerated() {
        banners.append(InlineBanner.Content(id: "installation-\(index)", message: warning))
    }
    if let error = context.settings.lastFileError {
        banners.append(InlineBanner.Content(id: "settings-file", message: error))
    }
    if let holder = context.controller.secureInput.holder {
        banners.append(InlineBanner.Content(
            id: "secure-input", message: "Hotkeys paused: \(holder.applicationName) is holding secure input."))
    }
    return banners
}

// MARK: General

struct GeneralSettingsView: View {
    let context: SettingsContext
    @ObservedObject private var permissions: PermissionMonitor
    @ObservedObject private var model: ModelController
    @ObservedObject private var settings: DictationSettings
    @ObservedObject private var controller: DictationController
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    init(context: SettingsContext) {
        self.context = context
        permissions = context.permissions
        model = context.model
        settings = context.settings
        controller = context.controller
    }

    var body: some View {
        SettingsPage(width: SettingsLayout.standardWidth, banners: commonBanners(context)) {
            SectionHeader(title: "Permissions", isFirst: true)
            permissionRow("Microphone", granted: permissions.microphoneGranted, anchor: "Privacy_Microphone")
            permissionRow("Accessibility", granted: permissions.accessibilityGranted, anchor: "Privacy_Accessibility")

            SectionHeader(title: "Speech model")
            modelRows

            SectionHeader(title: "Startup")
            SettingsRow(label: "Open at login", caption: loginItemError) {
                Toggle("Open at login", isOn: $launchesAtLogin).labelsHidden().toggleStyle(.switch)
            }
        }
        .onChange(of: launchesAtLogin) { _, enabled in updateLoginItem(enabled) }
    }

    private func permissionRow(_ label: String, granted: Bool, anchor: String) -> some View {
        SettingsRow(label: label) {
            HStack(spacing: SettingsLayout.rowSpacing) {
                StatusIndicator(isOK: granted, okText: "Allowed", problemText: "Not allowed")
                Spacer(minLength: 0)
                Button("Open System Settings") { permissions.openSystemSettings(anchor: anchor) }.controlSize(.large)
            }
        }
    }

    @ViewBuilder private var modelRows: some View {
        switch model.state {
        case .notInstalled:
            SettingsRow(label: "Status", caption: "Downloads about 1.23 GB once. Dictation then works offline.") {
                Button("Download model") { model.install() }.controlSize(.large)
            }
        case .installing(let phase, let fraction):
            SettingsRow(label: "Status", caption: "If the download stops, it resumes where it left off.") {
                HStack(spacing: SettingsLayout.rowSpacing) {
                    ProgressView(value: fraction) {
                        Text(phase == .downloading ? "Downloading" : phase == .validating ? "Checking files" : "Preparing for this Mac")
                            .font(.callout)
                    }
                    Button("Cancel") { model.cancelInstallation() }.controlSize(.large)
                }
            }
        case .loading:
            SettingsRow(label: "Status") {
                HStack(spacing: SettingsLayout.labelControlGap) {
                    ProgressView().controlSize(.small)
                    Text("Loading")
                }
            }
        case .ready:
            SettingsRow(label: "Status") {
                StatusIndicator(isOK: true, okText: "Ready", problemText: "")
            }
            SettingsRow(label: "Processor", caption: "The Neural Engine is fastest on most Macs.") {
                Picker("Processor", selection: $settings.configuration.computeTarget) {
                    Text("Neural Engine").tag(EncoderComputeTarget.neuralEngine)
                    Text("GPU").tag(EncoderComputeTarget.graphicsProcessor)
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            SettingsRow(label: "Storage") {
                Button("Remove model") { model.remove() }.controlSize(.large)
            }
        case .failed(let message):
            SettingsRow(label: "Status", caption: message) {
                Button("Retry download") { model.install() }.controlSize(.large)
            }
        }
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = "The login item could not be changed: \(error.localizedDescription)"
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: Hotkey

struct HotkeySettingsView: View {
    let context: SettingsContext
    @ObservedObject private var settings: DictationSettings
    @ObservedObject private var controller: DictationController
    @State private var recordingTarget: ShortcutRecordingTarget?

    init(context: SettingsContext) {
        self.context = context
        settings = context.settings
        controller = context.controller
    }

    private var triggerChoices: [TriggerKey] {
        var choices = TriggerKey.modifierChoices
        if case .key = settings.configuration.trigger { choices.append(settings.configuration.trigger) }
        return choices
    }

    var body: some View {
        SettingsPage(width: SettingsLayout.standardWidth, banners: commonBanners(context)) {
            SectionHeader(title: "Dictation", isFirst: true)
            SettingsRow(label: "Key", caption: "A function key, or a key with modifiers, also works.") {
                HStack(spacing: SettingsLayout.labelControlGap) {
                    Picker("Key", selection: $settings.configuration.trigger) {
                        ForEach(triggerChoices, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    Button("Press a key…") { recordingTarget = .trigger }.controlSize(.large)
                }
            }
            SettingsRow(label: "Mode", caption: modeCaption) {
                Picker("Mode", selection: $settings.configuration.triggerMode) {
                    ForEach(TriggerMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            SettingsRow(label: "Time limit") {
                Picker("Time limit", selection: $settings.configuration.maximumRecordingMinutes) {
                    ForEach([10, 20, 30, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }

            SectionHeader(title: "Other shortcuts")
            chordRow("Paste last text", chord: settings.configuration.repasteChord, target: .repaste) {
                settings.configuration.repasteChord = nil
            }
            chordRow("Pause hotkeys", chord: settings.configuration.pauseChord, target: .pause) {
                settings.configuration.pauseChord = nil
            }
        }
        .sheet(item: $recordingTarget) { target in
            ShortcutRecorderView(requiresModifier: target != .trigger, controller: controller) { chord in
                if let chord {
                    switch target {
                    case .trigger: settings.configuration.trigger = .key(chord)
                    case .repaste: settings.configuration.repasteChord = chord
                    case .pause: settings.configuration.pauseChord = chord
                    }
                }
                recordingTarget = nil
            }
        }
    }

    private var modeCaption: String {
        switch settings.configuration.triggerMode {
        case .toggle: return "Press to start, press again to stop."
        case .hold: return "Records while the key is held."
        case .doubleTapLock: return "Records while held. Double-tap to keep recording until the next press."
        }
    }

    private func chordRow(_ label: String, chord: KeyChord?, target: ShortcutRecordingTarget, clear: @escaping () -> Void) -> some View {
        SettingsRow(label: label) {
            HStack(spacing: SettingsLayout.labelControlGap) {
                Text(chord?.displayName ?? "None")
                    .foregroundStyle(chord == nil ? .secondary : .primary)
                    .frame(minWidth: 48, alignment: .leading)
                Button("Press a key…") { recordingTarget = target }.controlSize(.large)
                if chord != nil { Button("Clear", action: clear).controlSize(.large) }
            }
        }
    }
}

// MARK: Audio

struct AudioSettingsView: View {
    let context: SettingsContext
    @ObservedObject private var settings: DictationSettings
    @StateObject private var deviceCatalog = AudioInputDeviceCatalog()

    init(context: SettingsContext) {
        self.context = context
        settings = context.settings
    }

    var body: some View {
        SettingsPage(width: SettingsLayout.standardWidth, banners: commonBanners(context)) {
            SectionHeader(title: "Microphone", isFirst: true)
            SettingsRow(label: "Input") {
                Picker("Input", selection: $settings.configuration.inputDeviceIdentifier) {
                    Text("System default").tag(String?.none)
                    ForEach(deviceCatalog.devices) { Text($0.name).tag(String?.some($0.identifier)) }
                    if let selected = settings.configuration.inputDeviceIdentifier,
                        !deviceCatalog.devices.contains(where: { $0.identifier == selected })
                    {
                        Text("Unavailable microphone").tag(String?.some(selected))
                    }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            SectionHeader(title: "Recording")
            SettingsRow(label: "Stop after silence", caption: "Off lets you pause to think without ending the dictation.") {
                HStack(spacing: SettingsLayout.labelControlGap) {
                    Toggle("Stop after silence", isOn: $settings.configuration.stopsAfterSilence).labelsHidden().toggleStyle(.switch)
                    if settings.configuration.stopsAfterSilence {
                        Picker("Silence", selection: $settings.configuration.silenceStopSeconds) {
                            ForEach([2.0, 3.0, 5.0, 8.0], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                    }
                }
            }
            SettingsRow(label: "Sounds", caption: "A short sound when dictation starts and stops. All the way down turns it off.") {
                HStack(spacing: SettingsLayout.labelControlGap) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    // The start sound plays when the slider is released, at the new volume.
                    Slider(value: $settings.configuration.cueVolume, in: 0...1) { isEditing in
                        if !isEditing { context.controller.playStartCuePreview() }
                    }
                    .frame(width: 180)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: Text

struct TextSettingsView: View {
    let context: SettingsContext
    @ObservedObject private var settings: DictationSettings

    init(context: SettingsContext) {
        self.context = context
        settings = context.settings
    }

    var body: some View {
        SettingsPage(width: SettingsLayout.textWidth, banners: commonBanners(context)) {
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
        SettingsPage(width: SettingsLayout.historyWidth, banners: commonBanners(context)) {
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

// MARK: Shortcut capture

enum ShortcutRecordingTarget: String, Identifiable {
    case trigger, repaste, pause
    var id: String { rawValue }
}

/// Captures one key press with its modifiers. Escape cancels. When `requiresModifier` is false, a function key alone
/// is also accepted.
struct ShortcutRecorderView: View {
    let requiresModifier: Bool
    let controller: DictationController
    let completion: (KeyChord?) -> Void
    @State private var monitor: Any?

    var body: some View {
        VStack(spacing: SettingsLayout.rowSpacing) {
            Text("Press a key").font(.headline)
            Text(requiresModifier ? "Use a key with at least one modifier." : "Use a function key, or a key with at least one modifier.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Cancel") { finish(nil) }.controlSize(.large)
        }
        .padding(SettingsLayout.windowPadding)
        .frame(width: 320)
        .onAppear {
            controller.suspendsHotkeys = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == VirtualKey.escape {
                    finish(nil)
                    return nil
                }
                let modifiers = ModifierSet(eventFlags: UInt64(event.modifierFlags.rawValue))
                let isFunctionKey = VirtualKey.functionKeys[event.keyCode] != nil
                guard !modifiers.isEmpty || (isFunctionKey && !requiresModifier) else { return nil }
                finish(KeyChord(keyCode: event.keyCode, modifiers: modifiers))
                return nil
            }
        }
        .onDisappear { removeMonitor() }
    }

    private func finish(_ chord: KeyChord?) {
        removeMonitor()
        completion(chord)
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        controller.suspendsHotkeys = false
    }
}

/// Opens a file in the user's default text editor. JSON files otherwise open in whatever claims `.json`, often a browser.
enum TextEditorLauncher {
    @MainActor static func open(_ url: URL) {
        let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText)
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }
}
