import AppKit
import Combine
import DictationCore
import DictationEngine
import SwiftUI

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = DictationSettings()
    private let permissions = PermissionMonitor()
    private lazy var model = ModelController(computeTarget: settings.configuration.computeTarget)
    private lazy var controller = DictationController(settings: settings, permissions: permissions, model: model)
    private lazy var context = SettingsContext(settings: settings, permissions: permissions, model: model, controller: controller)
    private lazy var settingsWindow = SettingsWindowController(context: context)
    private let onboarding = OnboardingWindowController()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var subscriptions: Set<AnyCancellable> = []
    /// Keeps App Nap from delaying hotkey handling. Idle system sleep stays allowed; plain `.userInitiated` would
    /// keep the Mac awake for as long as the app runs.
    private var appNapActivity: NSObjectProtocol?
    private var commandServer: CommandServer?

    /// The menu bar icon does not change while dictating, because the heads-up display and the system microphone
    /// indicator already show that. It changes only when setup is needed, and then a click opens setup.
    private enum IconState: Equatable {
        case normal, error

        var symbol: String { self == .error ? "waveform.badge.exclamationmark" : "waveform" }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.updateIcon() }
        .store(in: &subscriptions)
        updateIcon()

        commandServer = CommandServer { [weak self] command in self?.handle(command) ?? "" }
        do {
            try commandServer?.start()
        } catch {
            dictationLog.error("command channel could not start: \(error.localizedDescription)")
        }

        if iconState == .error { showOnboarding() }
        InstallationCheck.current().recordLaunch()
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

    private var iconState: IconState { needsSetup ? .error : .normal }

    private func updateIcon() {
        let state = iconState
        statusItem.button?.image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: "Local Dictation")
    }

    /// In the error state a click opens setup; otherwise it shows the menu.
    @objc private func statusItemClicked() {
        if iconState == .error {
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addDisabledItem(statusText, to: menu)
        if let message = controller.lastMessage { addDisabledItem(message, to: menu) }
        let health = controller.eventTap.health
        if !health.isInstalled || !health.isEnabled { addDisabledItem("Hotkeys inactive: event tap not running", to: menu) }
        if let holder = controller.secureInput.holder { addDisabledItem("Hotkeys paused: \(holder.applicationName) is holding secure input", to: menu) }
        menu.addItem(.separator())

        let toggleTitle = controller.phase == .recording ? "Stop dictation" : "Start dictation"
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(toggleDictation), keyEquivalent: "")
        menu.addItem(toggle)
        if controller.lastTranscript != nil {
            menu.addItem(NSMenuItem(title: "Paste last text", action: #selector(repasteLastTranscript), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Copy last text", action: #selector(copyLastTranscript), keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem(
            title: controller.isPaused ? "Resume hotkeys" : "Pause hotkeys", action: #selector(togglePause), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Local Dictation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
    }

    private func addDisabledItem(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private var statusText: String {
        if controller.isPaused { return "Hotkeys paused" }
        switch controller.phase {
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .idle: break
        }
        switch model.state {
        case .notInstalled: return "Speech model not installed"
        case .installing: return "Installing speech model"
        case .loading: return "Loading speech model"
        case .failed: return "Speech model unavailable"
        case .ready: return "Ready. \(settings.configuration.trigger.displayName) to dictate."
        }
    }

    @objc private func toggleDictation() { controller.toggle() }
    @objc private func repasteLastTranscript() { controller.repasteLastTranscript() }
    @objc private func copyLastTranscript() { controller.copyLastTranscript() }
    @objc private func togglePause() { controller.togglePause() }

    @objc func showSettings() {
        settingsWindow.show()
    }

    private func showOnboarding() {
        onboarding.show(context: context)
    }
}

let commandLineArguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
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
