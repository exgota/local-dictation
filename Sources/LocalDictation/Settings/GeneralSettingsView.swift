import DictationEngine
import ServiceManagement
import SwiftUI

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
        SettingsPage(width: SettingsLayout.standardWidth, context: context) {
            SectionHeader(title: "Permissions", isFirst: true)
            permissionRow("Microphone", granted: permissions.microphoneGranted, anchor: PermissionMonitor.microphoneSettingsAnchor)
            permissionRow("Accessibility", granted: permissions.accessibilityGranted, anchor: PermissionMonitor.accessibilitySettingsAnchor)

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
                        Text(phase.displayName)
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
