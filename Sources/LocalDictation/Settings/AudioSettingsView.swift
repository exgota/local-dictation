import SwiftUI

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
        SettingsPage(width: SettingsLayout.standardWidth, context: context) {
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
