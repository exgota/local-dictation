import AppKit
import DictationCore
import SwiftUI

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
        SettingsPage(width: SettingsLayout.standardWidth, context: context) {
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
            controller.setHotkeysSuspended(true, for: .shortcutCapture)
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
        controller.setHotkeysSuspended(false, for: .shortcutCapture)
    }
}
