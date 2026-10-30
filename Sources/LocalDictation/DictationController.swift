import AppKit
import Combine
import DictationCore
import DictationEngine
import TextProcessing
import os


/// Orchestrates dictations: trigger → capture → transcription → insertion into the original target. One dictation
/// records at a time, and a new one can start while earlier ones are still transcribing.
@MainActor final class DictationController: ObservableObject {
    /// `recording` while a dictation records, even if earlier ones are still transcribing.
    enum Phase: Equatable { case idle, recording, transcribing }
    /// How the current recording was started, which decides what ends it.
    enum Trigger { case hold, toggle, locked }

    @Published private(set) var phase: Phase = .idle { didSet { publishTapState() } }
    /// The latest transcript, kept in memory only until the next dictation starts or the app quits, so a failed paste
    /// is recoverable.
    @Published private(set) var lastTranscript: String?
    @Published private(set) var lastMessage: String?
    /// Pause-all: the trigger and re-paste hotkeys do nothing until resumed.
    @Published private(set) var isPaused = false { didSet { publishTapState() } }
    /// True while Settings records a shortcut or a fixture, so the hotkeys do not start a dictation meanwhile.
    var suspendsHotkeys = false { didSet { publishTapState() } }

    let settings: DictationSettings
    let permissions: PermissionMonitor
    let model: ModelController
    let secureInput = SecureInputMonitor()
    let eventTap = HotkeyEventTap()
    private var hotkeys: HotkeyStateMachine
    private let recorder = AudioRecorder()
    private let headsUpDisplay = HeadsUpDisplayController()
    private let notice = NoticePanelController()
    private let fallback = FallbackPanelController()
    private let cues = CuePlayer()
    lazy var pipeline = TranscriptPipeline(settings: settings)

    /// The dictation being recorded.
    private struct Recording {
        let identifier: UUID
        var trigger: Trigger
        var target: InsertionTarget?
        let streaming: StreamingTranscription
    }

    /// A dictation that stopped recording and has not finished transcribing and inserting.
    private struct Delivery {
        let task: Task<Void, Never>
        let streaming: StreamingTranscription
    }

    private var recording: Recording?
    /// A delivery is removed when it finishes or is cancelled, so its task checks membership after every suspension.
    private var deliveries: [UUID: Delivery] = [:]
    /// Each delivery waits for the previous one before inserting, so transcripts land in the order they were spoken.
    private var latestDelivery: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var hotkeyInstallTimer: Timer?
    private var deadlineTimer: Timer?

    var onRequiresAttention: () -> Void = {}

    /// Recordings shorter than this hold no word and are discarded, so a stray tap of the trigger does nothing.
    nonisolated static let minimumRecordingDuration: TimeInterval = 0.3

    init(settings: DictationSettings, permissions: PermissionMonitor, model: ModelController) {
        self.settings = settings
        self.permissions = permissions
        self.model = model
        hotkeys = HotkeyStateMachine(configuration: settings.hotkeyConfiguration)

        eventTap.onEvent = { [weak self] event in self?.handle(event) }
        eventTap.sharedState.publish(configuration: settings.hotkeyConfiguration)
        recorder.onLevel = { [weak self] level in self?.headsUpDisplay.setLevel(level) }
        recorder.onMaximumDurationReached = { [weak self] in self?.maximumDurationReached() }
        recorder.onCaptureInterrupted = { [weak self] error in self?.finishRecording(interruption: error) }

        settings.$configuration
            .map { HotkeyConfiguration(trigger: $0.trigger, mode: $0.triggerMode, repasteChord: $0.repasteChord, pauseChord: $0.pauseChord) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] configuration in
                self?.hotkeys.configuration = configuration
                self?.eventTap.sharedState.publish(configuration: configuration)
            }
            .store(in: &subscriptions)
        settings.$configuration.map(\.computeTarget).removeDuplicates().dropFirst()
            .sink { [weak model] in model?.setComputeTarget($0) }.store(in: &subscriptions)
        secureInput.$holder.sink { [weak self] holder in self?.secureInputChanged(holder) }.store(in: &subscriptions)
        installHotkeysWhenPermitted()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.phase == .recording { self.finishRecording() }
            }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reinstallHotkeysAfterWake()
                self.recorder.restartAfterWake()
            }
        }
    }

    var hotkeysInstalled: Bool { eventTap.health.isInstalled }

    private func installHotkeysWhenPermitted() {
        if eventTap.install() { return }
        hotkeyInstallTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated {
                if self.eventTap.install() {
                    self.hotkeyInstallTimer?.invalidate()
                    dictationLog.notice("event tap installed")
                    self.objectWillChange.send()
                }
            }
        }
    }

    private func reinstallHotkeysAfterWake() {
        hotkeys.resetSession()
        if eventTap.health.isInstalled {
            dictationLog.notice("event tap reinstalled after wake: \(self.eventTap.reinstall())")
        }
    }

    private func publishTapState() {
        eventTap.sharedState.publish(dictationActive: phase != .idle, paused: isPaused || suspendsHotkeys)
        hotkeys.isPaused = isPaused || suspendsHotkeys
    }

    // MARK: Hotkey events

    private func handle(_ event: TappedKeyEvent) {
        switch event.kind {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            dictationLog.error("event tap disabled by \(event.kind == .tapDisabledByTimeout ? "timeout" : "user input"); re-enabled")
            objectWillChange.send()
            return
        default:
            break
        }
        guard let input = event.hotkeyInput else { return }
        for action in hotkeys.handle(input) { perform(action) }
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .toggle:
            toggle()
        case .holdBegan:
            begin(.hold)
        case .holdEnded:
            guard recording?.trigger == .hold else { return }
            if recorder.elapsed < Self.minimumRecordingDuration { cancel(playCue: true) } else { finishRecording() }
        case .holdInterrupted:
            // Another key joined the held trigger: a keyboard chord, never a dictation.
            guard recording?.trigger == .hold else { return }
            cancel(playCue: false)
        case .lockBegan:
            if recording?.trigger == .hold { recording?.trigger = .locked } else if recording == nil { begin(.locked) }
        case .lockEnded:
            if recording != nil { finishRecording() }
        case .escapePressed:
            if phase != .idle { cancel(playCue: true) }
        case .repasteRequested:
            repasteLastTranscript()
        case .pauseToggled:
            togglePause()
        case .scheduleDeadline(let deadline):
            deadlineTimer?.invalidate()
            deadlineTimer = Timer.scheduledTimer(withTimeInterval: max(0, deadline - monotonicSeconds()), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for action in self.hotkeys.handle(.deadlineElapsed(time: monotonicSeconds())) { self.perform(action) }
                }
            }
        }
    }

    private func showBriefly(_ message: String) {
        headsUpDisplay.showMessage(message, on: HeadsUpDisplayController.screenWithMouse())
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.phase == .idle else { return }
            self.headsUpDisplay.hide()
        }
    }

    func toggle() {
        if recording != nil { finishRecording() } else { begin(.toggle) }
    }

    func togglePause() {
        if !isPaused && phase != .idle {
            cancel(playCue: true)
            cancelDeliveries()
        }
        isPaused.toggle()
        hotkeys.resetSession()
        dictationLog.notice("hotkeys \(self.isPaused ? "paused" : "resumed")")
    }

    func repasteLastTranscript() {
        guard phase == .idle, let lastTranscript, let target = InsertionTarget.current() else { return }
        Task {
            let outcome = await TextInserter.insert(lastTranscript, into: target)
            dictationLog.notice("re-paste into \(target.applicationName): \(String(describing: outcome))")
        }
    }

    private func secureInputChanged(_ holder: SecureInputMonitor.Holder?) {
        if let holder {
            dictationLog.notice("secure input held by \(holder.applicationName)")
            notice.show("Hotkeys paused: \(holder.applicationName) is holding secure input")
        } else {
            notice.hide()
        }
        objectWillChange.send()
    }

    private func maximumDurationReached() {
        guard recording != nil else { return }
        dictationLog.notice("maximum recording duration reached")
        finishRecording()
        UserNotifications.post(
            title: "Recording stopped",
            body: "Dictation stopped after \(settings.configuration.maximumRecordingMinutes) minutes and transcribed what was recorded.")
    }

    // MARK: Session

    private func begin(_ trigger: Trigger) {
        guard recording == nil else { return }
        guard permissions.microphoneGranted, model.isReady else {
            dictationLog.notice("start refused: microphone \(self.permissions.microphoneGranted), model \(self.model.statusDescription)")
            if permissions.microphoneGranted, model.state == .loading {
                // The model is loading, which happens at launch and after a change of compute target: show a brief
                // message instead of opening a window.
                showBriefly("Model loading…")
                return
            }
            NSSound.beep()
            lastMessage = permissions.microphoneGranted ? "The speech model is not ready." : "Microphone access is required."
            onRequiresAttention()
            return
        }
        let target = InsertionTarget.current()
        let identifier = UUID()
        guard let streaming = model.makeStreamingTranscription(onActivity: { [weak self] activity in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.speechActivityChanged(activity, recording: identifier) } }
        }) else { return }
        do {
            try recorder.start(
                deviceIdentifier: settings.configuration.inputDeviceIdentifier,
                maximumDuration: TimeInterval(settings.configuration.maximumRecordingMinutes * 60),
                consumer: { samples in streaming.append(samples) },
                onFirstAudio: { [weak self] in self?.microphoneDeliveredFirstAudio(recording: identifier) })
        } catch {
            streaming.cancel()
            NSSound.beep()
            lastMessage = error.localizedDescription
            return
        }
        recording = Recording(identifier: identifier, trigger: trigger, target: target, streaming: streaming)
        dictationLog.notice("recording started (\(String(describing: trigger))) target \(target?.applicationName ?? "none")\(self.deliveries.isEmpty ? "" : ", \(self.deliveries.count) still transcribing")")
        if let target, target.focusedElement == nil { completeTarget(target, recording: identifier) }
        lastTranscript = nil
        lastMessage = nil
        updatePhase()
        fallback.hide()
        headsUpDisplay.showListening(on: HeadsUpDisplayController.screenWithMouse())
    }

    /// The start sound plays once the microphone is live, so speech that follows the sound is recorded from its first
    /// word.
    private func microphoneDeliveredFirstAudio(recording identifier: UUID) {
        guard recording?.identifier == identifier else { return }
        cues.playStart(volume: settings.configuration.cueVolume)
    }

    /// Plays the start sound at the configured volume, so the user hears a change to the volume setting.
    func playStartCuePreview() {
        cues.playStart(volume: settings.configuration.cueVolume)
    }

    /// Stops recording and transcribes. After a capture interruption the transcript is incomplete, so it goes to the
    /// clipboard with an explanation instead of being pasted.
    func finishRecording(interruption: Error? = nil) {
        guard let recording else { return }
        let held = recorder.elapsed
        let audioSeconds = recorder.finish()
        let stopTime = Date()
        endRecording()
        dictationLog.notice("recording stopped: \(String(format: "%.2f", audioSeconds)) s of audio")
        cues.playStop(volume: settings.configuration.cueVolume)
        let streaming = recording.streaming
        // A fraction of a second holds no word, and the model can hallucinate one from the padding.
        if held < Self.minimumRecordingDuration {
            streaming.cancel()
            // A microphone that failed right away is reported as itself, not as a short recording.
            let message = interruption?.localizedDescription ?? "The recording was too short."
            dictationLog.notice("completed: \(message)")
            lastMessage = message
            updateHeadsUpDisplay()
            return
        }
        let identifier = recording.identifier
        let target = recording.target
        let previous = latestDelivery
        let task = Task { [weak self] in
            let result: StreamingTranscriptionResult
            do {
                result = try await streaming.finish()
            } catch {
                guard let self, self.deliveries[identifier] != nil else { return }
                self.finishDelivery(identifier, message: error.localizedDescription)
                return
            }
            guard let self, self.deliveries[identifier] != nil, !Task.isCancelled else {
                dictationLog.notice("transcription finished after cancellation; discarded")
                return
            }
            dictationLog.notice("transcribed \(result.chunkCount) chunks, \(String(format: "%.1f", result.transcribedSeconds)) of \(String(format: "%.1f", result.audioSeconds)) s with speech: \(result.text.count) characters, stop to result \(String(format: "%.3f", Date().timeIntervalSince(stopTime))) s, of which model \(String(format: "%.3f", result.processingSecondsAfterEnd)) s")
            await previous?.value
            guard self.deliveries[identifier] != nil, !Task.isCancelled else { return }
            if let interruption {
                guard !result.text.isEmpty else { return self.finishDelivery(identifier, message: interruption.localizedDescription) }
                self.lastTranscript = result.text
                self.showFallback(result.text, reason: interruption.localizedDescription, onClipboard: true, delivery: identifier)
                return
            }
            await self.deliver(result.text, audioSeconds: result.audioSeconds, target: target, delivery: identifier)
        }
        deliveries[identifier] = Delivery(task: task, streaming: streaming)
        latestDelivery = task
        updatePhase()
        updateHeadsUpDisplay()
    }

    /// Asks again for the focused element every 250 ms during the first 3 s of recording, for applications that build
    /// their accessibility tree only after being asked (Chrome, Electron); Chrome took over a second the first time.
    /// Only the same frontmost application is accepted, so the element found belongs to the application the dictation
    /// started in.
    private func completeTarget(_ target: InsertionTarget, recording identifier: UUID) {
        Task { [weak self] in
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, self.recording?.identifier == identifier else { return }
                if let completed = target.withFocusedElement() {
                    self.recording?.target = completed
                    dictationLog.notice("focused element found after asking \(target.applicationName) again")
                    return
                }
            }
        }
    }

    /// Optional silence auto-stop, off by default.
    private func speechActivityChanged(_ activity: StreamingTranscription.Activity, recording identifier: UUID) {
        guard recording?.identifier == identifier, settings.configuration.stopsAfterSilence, activity.hasDetectedSpeech,
            activity.trailingSilence >= settings.configuration.silenceStopSeconds
        else { return }
        dictationLog.notice("silence auto-stop")
        finishRecording()
    }

    /// Delivers the transcript of `delivery` into the target captured when it was recorded. After every suspension it
    /// checks that the delivery was not cancelled, so a cancelled dictation never inserts.
    private func deliver(_ rawText: String, audioSeconds: Double, target: InsertionTarget?, delivery: UUID) async {
        guard !rawText.isEmpty else {
            finishDelivery(delivery, message: "No speech was recognized.")
            return
        }
        let prepared = pipeline.prepare(rawText, bundleIdentifier: target?.bundleIdentifier)
        guard deliveries[delivery] != nil, !Task.isCancelled else { return }
        guard prepared.profile.producesText else {
            finishDelivery(delivery, message: "Dictation is turned off in \(target?.applicationName ?? "this application").")
            return
        }
        let text = prepared.finalText
        // History and transcript files are written after insertion, and never for text a password field refused.
        let record = {
            await self.pipeline.record(
                rawText: rawText, finalText: text, durationSeconds: audioSeconds, applicationName: target?.applicationName,
                bundleIdentifier: target?.bundleIdentifier, style: prepared.profile)
        }
        guard let target else {
            lastTranscript = text
            showFallback(text, reason: "No text field had focus", onClipboard: true, delivery: delivery)
            await record()
            return
        }
        let outcome = await TextInserter.insert(text, into: target, onLanded: { [weak self] in self?.deliveryLanded(delivery) })
        guard deliveries[delivery] != nil else { return }
        // Finish the dictation first, then write history: the write is the last suspension and touches no session state.
        switch outcome {
        case .inserted(let method):
            dictationLog.notice("inserted into \(target.applicationName) by \(method.rawValue) with profile \(prepared.profile.rawValue)")
            if prepared.submitsWithReturn && target.isStillFocused() { TextInserter.postKey(36, flags: []) }
            finishDelivery(delivery, message: nil)
        case .refusedSecureField:
            showFallback(text, reason: "Password fields are not dictated into", onClipboard: false, delivery: delivery)
        case .noEditableFocus:
            showFallback(text, reason: "No text field had focus", onClipboard: true, delivery: delivery)
        case .targetChanged:
            showFallback(text, reason: "Focus moved before the text was inserted", onClipboard: true, delivery: delivery)
        case .unconfirmed:
            // Not every unconfirmed path leaves the transcript on the clipboard, so it is put there explicitly.
            showFallback(text, reason: "The text could not be confirmed as inserted", onClipboard: true, delivery: delivery)
        case .cancelled:
            return
        }
        switch outcome {
        case .refusedSecureField, .cancelled:
            break
        case .inserted, .noEditableFocus, .targetChanged, .unconfirmed:
            // Kept until the next dictation so it can be re-pasted or copied from the menu.
            lastTranscript = text
            await record()
        }
    }

    private func showFallback(_ text: String, reason: String, onClipboard: Bool, delivery: UUID) {
        if onClipboard { TextInserter.placeOnClipboard(text) }
        fallback.show(text: text, reason: reason)
        finishDelivery(delivery, message: reason + ".")
    }

    /// The text is in the target. The display goes away now, not when the clipboard is restored a moment later, unless
    /// a newer dictation is recording or still transcribing.
    private func deliveryLanded(_ delivery: UUID) {
        guard recording == nil, deliveries.count == 1, deliveries[delivery] != nil else { return }
        headsUpDisplay.hide()
    }

    private func updatePhase() {
        phase = recording != nil ? .recording : deliveries.isEmpty ? .idle : .transcribing
    }

    private func updateHeadsUpDisplay() {
        switch phase {
        case .idle: headsUpDisplay.hide()
        case .recording: headsUpDisplay.showListening(on: HeadsUpDisplayController.screenWithMouse())
        case .transcribing: headsUpDisplay.showTranscribing()
        }
    }

    /// Ends the recording without touching earlier dictations that are still transcribing.
    private func endRecording() {
        recording = nil
        hotkeys.resetSession()
        updatePhase()
    }

    private func finishDelivery(_ delivery: UUID, message: String?) {
        if let message { dictationLog.notice("completed: \(message)") }
        lastMessage = message
        deliveries[delivery] = nil
        if deliveries.isEmpty { latestDelivery = nil }
        updatePhase()
        // A newer recording keeps its listening display.
        if phase != .recording { updateHeadsUpDisplay() }
    }

    /// Escape cancels the recording if there is one, otherwise every dictation still transcribing.
    func cancel(playCue: Bool) {
        guard phase != .idle else { return }
        if let recording {
            dictationLog.notice("cancelled during recording")
            // Clearing the recording first guarantees that nothing it captured is transcribed or inserted.
            endRecording()
            recording.streaming.cancel()
            recorder.cancel()
        } else {
            cancelDeliveries()
        }
        if playCue { cues.playStop(volume: settings.configuration.cueVolume) }
        lastMessage = nil
        updateHeadsUpDisplay()
    }

    private func cancelDeliveries() {
        guard !deliveries.isEmpty else { return }
        dictationLog.notice("cancelled during transcription")
        // Removing a delivery first guarantees that a transcription finishing later cannot insert anything.
        let cancelled = deliveries.values
        deliveries.removeAll()
        latestDelivery = nil
        for delivery in cancelled {
            delivery.task.cancel()
            delivery.streaming.cancel()
        }
        updatePhase()
    }

    func copyLastTranscript() {
        if let lastTranscript { TextInserter.placeOnClipboard(lastTranscript) }
    }

}
