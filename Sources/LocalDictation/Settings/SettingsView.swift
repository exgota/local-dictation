import AppKit
import DictationCore
import SwiftUI

struct SettingsNotices {
    var accessibilityOff = false
    var microphoneOff = false
    var model: ModelController.State = .ready
}

struct PreferenceRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control
    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label + ":").gridColumnAlignment(.trailing)
            control.gridColumnAlignment(.leading)
        }
    }
}

struct PreferenceGroupGap: View {
    var body: some View { GridRow { Color.clear.frame(height: 8).gridCellColumns(2) } }
}

struct SettingsView: View {
    @ObservedObject var settings: DictationSettings
    var notices = SettingsNotices()
    var showHistory: () -> Void = {}
    var suspendShortcuts: (Bool) -> Void = { _ in }
    var previewSound: () -> Void = {}
    var openPermission: (String) -> Void = { _ in }
    var download: () -> Void = {}
    var cancelDownload: () -> Void = {}
    @StateObject private var deviceCatalog = AudioInputDeviceCatalog()
    @State private var showsExceptions = false
    @State private var showsCorrections = false
    @State private var capturesKey = false
    @State private var folderMenu = 0

    private var triggerChoices: [TriggerKey] {
        var choices: [TriggerKey] = [.function, .rightCommand, .rightOption]
        if case .key = settings.configuration.trigger { choices.append(settings.configuration.trigger) }
        return choices
    }
    private var triggerSelection: Binding<Int> {
        Binding(get: { triggerChoices.firstIndex(of: settings.configuration.trigger) ?? 0 }, set: { index in
            if triggerChoices.indices.contains(index) { settings.configuration.trigger = triggerChoices[index] }
            else { capturesKey = true }
        })
    }
    private var deviceIdentifiers: [String?] {
        var identifiers: [String?] = [nil] + deviceCatalog.devices.map { Optional($0.identifier) }
        if let selected = settings.configuration.inputDeviceIdentifier, !identifiers.contains(selected) { identifiers.append(selected) }
        return identifiers
    }
    private var deviceNames: [String] {
        ["System Default"] + deviceIdentifiers.dropFirst().map { identifier in
            deviceCatalog.devices.first { $0.identifier == identifier }?.name ?? "Unavailable Microphone"
        }
    }
    private var silenceValues: [Double] {
        var values = [2.0, 3.0, 5.0, 8.0]
        if !values.contains(settings.configuration.silenceStopSeconds) { values.append(settings.configuration.silenceStopSeconds); values.sort() }
        return values
    }
    private var recordingLimits: [Int] {
        Array(Set([10, 20, 30, 60, settings.configuration.maximumRecordingMinutes])).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            noticeRows
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                PreferenceRow(label: "Dictation key") {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsPopUpButton(items: triggerChoices.map(\.displayName) + ["-", "Other Key…"], selection: triggerSelection, width: SettingsControlWidth.wide)
                        SettingsPopUpButton(items: SettingsControlWidth.behaviors, selection: Binding(
                            get: { TriggerMode.allCases.firstIndex(of: settings.configuration.triggerMode) ?? 0 },
                            set: { settings.configuration.triggerMode = TriggerMode.allCases[$0] }), width: SettingsControlWidth.wide)
                    }
                }
                PreferenceRow(label: "Paste last text") {
                    SettingsShortcutField(chord: $settings.configuration.repasteChord, suspendShortcuts: suspendShortcuts)
                }
                PreferenceRow(label: "Pause all shortcuts") {
                    SettingsShortcutField(chord: $settings.configuration.pauseChord, suspendShortcuts: suspendShortcuts)
                }
                PreferenceGroupGap()
                PreferenceRow(label: "Microphone") {
                    SettingsPopUpButton(items: [deviceNames[0], "-"] + deviceNames.dropFirst(), selection: Binding(
                        get: { let index = deviceIdentifiers.firstIndex(of: settings.configuration.inputDeviceIdentifier) ?? 0; return index == 0 ? 0 : index + 1 },
                        set: { index in settings.configuration.inputDeviceIdentifier = deviceIdentifiers[index == 0 ? 0 : index - 1] }), width: SettingsControlWidth.wide)
                }
                PreferenceRow(label: "Dictation sounds") {
                    Slider(value: $settings.configuration.cueVolume) { EmptyView() } minimumValueLabel: {
                        Image(systemName: "speaker.slash.fill").foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    } onEditingChanged: { editing in if !editing { previewSound() } }
                    .frame(width: 210)
                }
                PreferenceRow(label: "Stop after silence") {
                    SettingsPopUpButton(items: ["Never", "-"] + silenceValues.map { "\($0.formatted()) seconds" }, selection: Binding(
                        get: { settings.configuration.stopsAfterSilence ? (silenceValues.firstIndex(of: settings.configuration.silenceStopSeconds) ?? 1) + 2 : 0 },
                        set: { index in
                            settings.configuration.stopsAfterSilence = index > 1
                            if index > 1 { settings.configuration.silenceStopSeconds = silenceValues[index - 2] }
                        }), width: SettingsControlWidth.narrow)
                }
                PreferenceRow(label: "Recording limit") {
                    SettingsPopUpButton(items: recordingLimits.map { $0 == 60 ? "1 hour" : "\($0) minutes" }, selection: Binding(
                        get: { recordingLimits.firstIndex(of: settings.configuration.maximumRecordingMinutes) ?? 0 },
                        set: { settings.configuration.maximumRecordingMinutes = recordingLimits[$0] }), width: SettingsControlWidth.narrow)
                }
                PreferenceGroupGap()
                PreferenceRow(label: "Text") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Remove fillers and format text", isOn: Binding(
                            get: { settings.configuration.profiles.defaultProfile == .chat },
                            set: { settings.configuration.profiles.defaultProfile = $0 ? .chat : .verbatim }))
                        HStack(spacing: 8) {
                            Toggle("Apply corrections", isOn: $settings.configuration.vocabularyCorrectionsEnabled)
                            Button("Edit Corrections…") { showsCorrections = true }.disabled(!settings.configuration.vocabularyCorrectionsEnabled)
                        }
                        Button("App Exceptions…") { showsExceptions = true }
                    }
                }
                PreferenceGroupGap()
                PreferenceRow(label: "History") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Toggle("Keep a list of dictations", isOn: $settings.configuration.keepsHistory)
                            Button("Show History", action: showHistory).disabled(!settings.configuration.keepsHistory)
                        }
                        HStack(spacing: 6) {
                            Toggle("Save text files to:", isOn: $settings.configuration.transcriptFolder.isEnabled)
                            Picker("", selection: $folderMenu) {
                                Label(settings.configuration.transcriptFolder.url.lastPathComponent, systemImage: "folder").tag(0)
                                Divider()
                                Text("Other…").tag(1)
                            }
                            .labelsHidden().fixedSize().disabled(!settings.configuration.transcriptFolder.isEnabled)
                            .onChange(of: folderMenu) { _, new in if new == 1 { folderMenu = 0; chooseFolder() } }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 28)
        .frame(width: 500).fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showsExceptions) { AppExceptionsSheet(settings: settings) }
        .sheet(isPresented: $showsCorrections) { CorrectionsSheet() }
        .sheet(isPresented: $capturesKey) {
            DictationKeyCaptureSheet(suspendShortcuts: suspendShortcuts) { trigger in
                if let trigger { settings.configuration.trigger = trigger }
                capturesKey = false
            }
        }
    }

    @ViewBuilder private var noticeRows: some View {
        let modelProblem: Bool = {
            switch notices.model { case .notInstalled, .installing, .failed: true; default: false }
        }()
        if notices.accessibilityOff || notices.microphoneOff || modelProblem {
            VStack(alignment: .leading, spacing: 10) {
                if notices.accessibilityOff {
                    notice("Accessibility access is off.", action: "Open System Settings") { openPermission(PermissionMonitor.accessibilitySettingsAnchor) }
                }
                if notices.microphoneOff {
                    notice("Microphone access is off.", action: "Open System Settings") { openPermission(PermissionMonitor.microphoneSettingsAnchor) }
                }
                switch notices.model {
                case .notInstalled:
                    notice("The speech model isn’t downloaded.", action: "Download", perform: download)
                case .failed:
                    notice("The speech model is unavailable.", action: "Download", perform: download)
                case .installing(let phase, let progress):
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary).frame(width: 18)
                        Text(phase == .downloading ? "Downloading speech model" : phase.displayName).fixedSize()
                        ProgressView(value: progress).frame(maxWidth: .infinity)
                        Text("\(Int(progress * 100))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                        Spacer(minLength: 12)
                        Button("Cancel", action: cancelDownload)
                    }
                default: EmptyView()
                }
            }
        }
    }

    private func notice(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).frame(width: 18)
            Text(text).fixedSize()
            Spacer(minLength: 12)
            Button(action, action: perform)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = settings.configuration.transcriptFolder.url.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            settings.configuration.transcriptFolder.path = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}
