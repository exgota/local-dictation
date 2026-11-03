import AppKit
import Combine
import DictationCore
import DictationEngine
import MoonRendering
import Sparkle
import ServiceManagement
import SwiftUI

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, @MainActor SPUStandardUserDriverDelegate {
    private let settings = DictationSettings()
    private let permissions = PermissionMonitor()
    private lazy var model = ModelController(computeTarget: settings.configuration.computeTarget)
    private lazy var controller = DictationController(settings: settings, permissions: permissions, model: model)
    private lazy var context = SettingsContext(settings: settings, permissions: permissions, model: model, controller: controller)
    private lazy var settingsWindow = SettingsWindowController(context: context, showHistory: { [weak self] in self?.showHistory() })
    private lazy var historyWindow = HistoryWindowController(pipeline: controller.pipeline)
    private var loginItemError: String?
    private let onboarding = OnboardingWindowController()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var menuHeader: MenuMoonHeaderView?
    private var menuIsOpen = false
    private var subscriptions: Set<AnyCancellable> = []
    /// Keeps App Nap from delaying hotkey handling. Idle system sleep stays allowed; plain `.userInitiated` would
    /// keep the Mac awake for as long as the app runs.
    private var appNapActivity: NSObjectProtocol?
    private var commandServer: CommandServer?
    private var updaterController: SPUStandardUpdaterController?
    private var hasPendingUpdate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Complete library loading, pipeline creation and the warm-up draw before any moon window can appear.
        if case .failure(let error) = MoonRenderer.shared {
            dictationLog.error("Moon renderer could not start: \(error.localizedDescription)")
        }
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep], reason: "Global dictation hotkeys")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        controller.onRequiresAttention = { [weak self] in self?.showOnboarding() }
        Publishers.Merge4(
            controller.$phase.map { _ in () }, controller.$isPaused.map { _ in () },
            permissions.objectWillChange.map { _ in () }, model.$state.map { _ in () }
        )
        .merge(with: controller.objectWillChange.map { _ in () })
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.updateIcon() }
        .store(in: &subscriptions)
        updateIcon()

        commandServer = CommandServer { [weak self] command in self?.handle(command) ?? "" }
        do {
            try commandServer?.start()
        } catch {
            dictationLog.error("command channel could not start: \(error.localizedDescription)")
        }

        if iconState.opensSetup { showOnboarding() }
        InstallationCheck.current().recordLaunch()
        // Source builds remain usable before the release signing key is configured.
        if let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
           Data(base64Encoded: publicKey)?.count == 32 {
            UserNotifications.configureUpdateAction { [weak self] in self?.checkForUpdates() }
            updaterController = SPUStandardUpdaterController(
                startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
            do { try updaterController?.updater.start() }
            catch { dictationLog.error("Update checks could not start: \(error.localizedDescription)") }
        }
    }

    /// True when a permission is not granted, the event tap is not installed, or the model is not installed or has
    /// failed.
    private var needsSetup: Bool {
        if !permissions.allGranted || !controller.hotkeysInstalled { return true }
        switch model.state {
        case .notInstalled, .failed: return true
        case .installing, .loading, .ready: return false
        }
    }

    private var iconState: StatusItemIcon {
        StatusItemIcon(needsSetup: needsSetup, secureInputBlocked: controller.secureInput.holder != nil)
    }

    private func updateIcon() {
        let state = iconState
        statusItem.button?.image = state.image
        if menuIsOpen { menuHeader?.update(title: statusHeader.title, subtitle: statusDetail, phase: statusHeader.moonPhase) }
    }

    /// Setup errors open setup; secure input and ordinary states open the menu.
    @objc private func statusItemClicked() {
        if iconState.opensSetup {
            showOnboarding()
            return
        }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Runs a command from a second launch or the command line. Returns the reply sent back to the sender.
    private func handle(_ command: CommandChannel.Command) -> String {
        dictationLog.notice("command received: \(command.rawValue)")
        switch command {
        case .showSettings: needsSetup ? showOnboarding() : showSettings()
        case .showSetup: showOnboarding()
        case .toggleTranscription: controller.toggle()
        case .cancel: controller.cancel(playCue: true)
        case .report:
            let runtime = DoctorReport.RuntimeState(
                microphoneGranted: permissions.microphoneGranted, accessibilityGranted: permissions.accessibilityGranted,
                tapHealth: controller.eventTap.health, modelState: model.statusDescription, modelReady: model.isReady,
                trigger: settings.configuration.trigger, inputDeviceIdentifier: settings.configuration.inputDeviceIdentifier)
            let report = DoctorReport.collect(runtime: runtime, configuration: settings.configuration)
            return (try? JSONEncoder().encode(report)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        return "ok"
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        needsSetup ? showOnboarding() : showSettings()
        return true
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menuHeader = StatusMenu.populate(menu, state: StatusMenu.State(
            header: statusHeader, detail: statusDetail, recording: controller.phase == .recording,
            trigger: settings.configuration.trigger, pasteChord: settings.configuration.repasteChord,
            canPaste: controller.lastTranscript != nil, keepsHistory: settings.configuration.keepsHistory,
            paused: controller.isPaused, opensAtLogin: SMAppService.mainApp.status == .enabled,
            hasPendingUpdate: hasPendingUpdate), target: self)
    }

    private var statusDetail: String {
        if let holder = controller.secureInput.holder { return holder.statusDetail }
        if let loginItemError { return loginItemError }
        if !permissions.accessibilityGranted { return "Accessibility access is off" }
        if !permissions.microphoneGranted { return "Microphone access is off" }
        let health = controller.eventTap.health
        if !health.isInstalled || !health.isEnabled { return "Shortcuts are unavailable" }
        switch model.state {
        case .notInstalled: return "Speech model is not downloaded"
        case .failed: return "Speech model is unavailable"
        default: return ""
        }
    }

    private var statusHeader: StatusMenu.HeaderState {
        if controller.secureInput.holder != nil { return .blocked }
        if controller.isPaused { return .paused }
        switch controller.phase {
        case .recording: return .listening
        case .transcribing: return .transcribing
        case .idle: break
        }
        return model.isReady ? .ready : .loading
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate, !hasPendingUpdate else { return }
        hasPendingUpdate = true
        if menuIsOpen { menuNeedsUpdate(menu) }
        UserNotifications.postUpdateAvailable(displayVersion: update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        removeUpdateReminders()
    }

    func standardUserDriverWillFinishUpdateSession() {
        removeUpdateReminders()
    }

    private func removeUpdateReminders() {
        hasPendingUpdate = false
        if menuIsOpen { menuNeedsUpdate(menu) }
        UserNotifications.removeUpdateAvailable()
    }

    @objc func checkForUpdates() { updaterController?.checkForUpdates(nil) }

    @objc func toggleDictation() { controller.toggle() }
    @objc func repasteLastTranscript() { controller.repasteLastTranscript() }
    @objc func togglePause() { controller.togglePause() }

    @objc func showSettings() {
        settingsWindow.show()
    }

    @objc func showHistory() { historyWindow.show() }

    @objc func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            loginItemError = nil
        } catch { loginItemError = "Open at login could not be changed" }
    }

    private func showOnboarding() {
        onboarding.show(context: context)
    }
}

let commandLineArguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
#if DEBUG || MOON_DIAGNOSTICS
if commandLineArguments.first == "--render-setup", commandLineArguments.count == 2 {
    MainActor.assumeIsolated {
        do { try SetupDiagnostics.render(directory: URL(fileURLWithPath: commandLineArguments[1])) }
        catch { print("Setup render failed: \(error)"); exit(1) }
    }
    exit(0)
}
if commandLineArguments == ["--measure-moon-startup"] {
    MainActor.assumeIsolated {
        do { try MoonDiagnostics.measureStartup() }
        catch { print("Moon startup measurement failed: \(error)"); exit(1) }
    }
    exit(0)
}
if commandLineArguments.first == "--render-park-parity", commandLineArguments.count == 3 {
    MainActor.assumeIsolated {
        do { try MoonDiagnostics.renderPark(states: URL(fileURLWithPath: commandLineArguments[1]), directory: URL(fileURLWithPath: commandLineArguments[2])) }
        catch { print("Park render failed: \(error)"); exit(1) }
    }
    exit(0)
}
if commandLineArguments.first == "--render-interface", commandLineArguments.count == 2 {
    MainActor.assumeIsolated {
        do { try InterfaceDiagnostics.render(directory: URL(fileURLWithPath: commandLineArguments[1])) }
        catch { print("Interface render failed: \(error)"); exit(1) }
    }
    exit(0)
}
if commandLineArguments == ["--benchmark-moon"] {
    MainActor.assumeIsolated {
        do { try MoonDiagnostics.benchmark() }
        catch { print("Moon benchmark failed: \(error)"); exit(1) }
    }
    exit(0)
}
if ["--render-moon-parity", "--render-moon-tones"].contains(commandLineArguments.first ?? ""), commandLineArguments.count == 3 {
    MainActor.assumeIsolated {
        do {
            try MoonDiagnostics.render(states: URL(fileURLWithPath: commandLineArguments[1]),
                                       directory: URL(fileURLWithPath: commandLineArguments[2]),
                                       capturesTone: commandLineArguments.first == "--render-moon-tones")
        } catch { print("Moon render failed: \(error)"); exit(1) }
    }
    exit(0)
}
if commandLineArguments.first == "--generate-application-icon", commandLineArguments.count == 2 {
    MainActor.assumeIsolated {
        do { try MoonDiagnostics.generateIcon(directory: URL(fileURLWithPath: commandLineArguments[1])) }
        catch { print("Icon generation failed: \(error)"); exit(1) }
    }
    exit(0)
}
#endif
if let first = commandLineArguments.first, first.hasPrefix("--") {
    Task { @MainActor in exit(await CommandLineInterface.run(commandLineArguments)) }
    dispatchMain()
}

// Single instance: a second launch asks the running one to show Settings, then exits.
if CommandChannel.runningInstance != nil {
    _ = CommandChannel.send(.showSettings)
    exit(0)
}

CrashReporter.install()
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = ApplicationDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
