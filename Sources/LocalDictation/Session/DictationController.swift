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
    /// The latest transcript, kept in memory only until another usable transcript replaces it or the app quits, so a failed paste
    /// is recoverable.
    @Published private(set) var lastTranscript: String?
    @Published private(set) var lastMessage: String?
    /// Pause-all: the trigger and re-paste hotkeys do nothing until resumed.
    @Published private(set) var isPaused = false { didSet { publishTapState() } }
    enum HotkeySuspensionReason: Hashable { case shortcutCapture }
    private var hotkeySuspensionReasons: Set<HotkeySuspensionReason> = [] { didSet { publishTapState() } }

    func setHotkeysSuspended(_ suspended: Bool, for reason: HotkeySuspensionReason) {
        if suspended { hotkeySuspensionReasons.insert(reason) } else { hotkeySuspensionReasons.remove(reason) }
    }

    let settings: DictationSettings
    let permissions: PermissionMonitor
    let model: ModelController
    let secureInput = SecureInputMonitor()
    let eventTap = HotkeyEventTap()
    private var hotkeys: HotkeyStateMachine
    private let recorder = AudioRecorder()
    private let headsUpDisplay = HeadsUpDisplayController()
    private let cues = CuePlayer()
    lazy var pipeline = TranscriptPipeline(settings: settings)

    /// The dictation being recorded.
    private struct Recording {
        let identifier: UUID
        var trigger: Trigger
        var target: InsertionTarget?
        let streaming: RecordingTranscription
    }

    /// A dictation that stopped recording and has not finished transcribing and inserting.
    private struct Delivery {
        let appearance: HeadsUpDisplayController.StoppedAppearance?
        let task: Task<Void, Never>
        let streaming: RecordingTranscription
        let lifecycle: DeliveryLifecycle
        let target: InsertionTarget?
        let clipboardChangeCount: Int
        var result: StreamingTranscriptionResult?
    }

    private var recording: Recording?
    /// A delivery is removed when it finishes or is cancelled, so its task checks membership after every suspension.
    private var deliveries: [UUID: Delivery] = [:]
    /// Each delivery waits for the previous one before inserting, so transcripts land in the order they were spoken.
    private var latestDelivery: DeliveryLifecycle?
    private var subscriptions: Set<AnyCancellable> = []
    private var hotkeyInstallTimer: Timer?
    private var deadlineTimer: Timer?
    private var microphoneSilence: MicrophoneSilenceMonitor?
    private var microphoneSilenceTimer: Timer?
    private var isShowingSilentMicrophone = false
    private var briefDisplayIdentifier: UUID?

    var onRequiresAttention: () -> Void = {}

    /// Recordings shorter than this hold no word and are discarded, so a stray tap of the trigger does nothing.
    nonisolated static let minimumRecordingDuration: TimeInterval = 0.3

    init(settings: DictationSettings, permissions: PermissionMonitor, model: ModelController) {
        self.settings = settings
        self.permissions = permissions
        self.model = model
        hotkeys = HotkeyStateMachine(configuration: settings.configuration.hotkeyConfiguration)

        headsUpDisplay.onParkVisibilityChanged = { [weak self] in self?.publishTapState() }
        eventTap.onEvent = { [weak self] event in self?.handle(event) }
        eventTap.sharedState.publish(configuration: settings.configuration.hotkeyConfiguration)
        recorder.onLevel = { [weak self] level in
            self?.headsUpDisplay.setLevel(level)
            self?.microphoneSilence?.receive(decibels: level, at: monotonicSeconds())
        }
        recorder.onMaximumDurationReached = { [weak self] in self?.maximumDurationReached() }
        recorder.onCaptureInterrupted = { [weak self] error in self?.finishRecording(interruption: error) }

        settings.$configuration
            .map(\.hotkeyConfiguration)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] configuration in
                self?.hotkeys.configuration = configuration
                self?.eventTap.sharedState.publish(configuration: configuration)
            }
            .store(in: &subscriptions)
        settings.$configuration.map(\.computeTarget).removeDuplicates().dropFirst()
            .sink { [weak model] in model?.setComputeTarget($0) }.store(in: &subscriptions)
        model.$state.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.modelReadinessChanged()
        }.store(in: &subscriptions)
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
        eventTap.sharedState.publish(dictationActive: phase != .idle || headsUpDisplay.isParked, paused: isPaused, suspended: !hotkeySuspensionReasons.isEmpty)
        hotkeys.isPaused = isPaused || !hotkeySuspensionReasons.isEmpty
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
        guard hotkeySuspensionReasons.isEmpty else { return }
        if event.kind == .keyDown && !event.isRepeat {
            if event.keyCode == VirtualKey.escape && headsUpDisplay.isParked { headsUpDisplay.dismissPark() }
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

    private func showBriefly(_ show: () -> Void) {
        let identifier = UUID()
        briefDisplayIdentifier = identifier
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.briefDisplayIdentifier == identifier else { return }
            self.briefDisplayIdentifier = nil
            if self.phase == .idle { self.headsUpDisplay.hide() }
            if self.phase == .transcribing { self.headsUpDisplay.showTranscribing() }
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
        let text = lastTranscript
        let target = InsertionTarget.current()
        Task {
            _ = await LastTranscriptPaste.perform(text: text, target: target,
                onInserted: { self.headsUpDisplay.releasePark() })
        }
    }

    private func secureInputChanged(_ holder: SecureInputMonitor.Holder?) {
        if let holder {
            dictationLog.notice("secure input held by \(holder.applicationName)")
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
        guard permissions.microphoneGranted, model.isReady || model.state == .loading else {
            dictationLog.notice("start refused: microphone \(self.permissions.microphoneGranted), model \(self.model.statusDescription)")
            NSSound.beep()
            lastMessage = permissions.microphoneGranted ? "The speech model is not ready." : "Microphone access is required."
            onRequiresAttention()
            return
        }
        let target = InsertionTarget.current()
        let identifier = UUID()
        let maximumDuration = TimeInterval(settings.configuration.maximumRecordingMinutes * 60)
        let streaming = RecordingTranscription(
            maximumSamples: Int(maximumDuration) * SpeechAudioFormat.sampleRate,
            stream: makeStream(recording: identifier),
            onLimit: { [weak self] in
                Task { @MainActor in
                    guard self?.recording?.identifier == identifier else { return }
                    self?.maximumDurationReached()
                }
            })
        streaming.onModelUnavailable = { [weak self] in
            guard let self else { return }
            NSSound.beep()
            self.lastMessage = "The speech model is unavailable. The recording is kept until it is ready or you cancel."
            if self.recording == nil { self.updateHeadsUpDisplay() }
        }
        do {
            try recorder.start(
                deviceIdentifier: settings.configuration.inputDeviceIdentifier,
                maximumDuration: maximumDuration,
                consumer: { samples in streaming.audio.append(samples) },
                onFirstAudio: { [weak self] in self?.microphoneDeliveredFirstAudio(recording: identifier) })
        } catch {
            streaming.cancel()
            NSSound.beep()
            lastMessage = error.localizedDescription
            if (error as? AudioRecorderError)?.showsMicrophoneWarning == true {
                showBriefly { headsUpDisplay.showSilentMicrophone() }
            }
            return
        }
        briefDisplayIdentifier = nil
        recording = Recording(identifier: identifier, trigger: trigger, target: target, streaming: streaming)
        dictationLog.notice("recording started (\(String(describing: trigger))) target \(target?.applicationName ?? "none")\(self.deliveries.isEmpty ? "" : ", \(self.deliveries.count) still transcribing")")
        if let target, target.focusedElement == nil, target.setupTextTarget == nil { completeTarget(target, recording: identifier) }
        lastMessage = nil
        updatePhase()
        headsUpDisplay.showListening(on: NSScreen.screenWithMouse())
        watchForSilentMicrophone()
    }

    /// The recording keeps running under the warning, and the moon returns when sound resumes.
    private func watchForSilentMicrophone() {
        microphoneSilence = MicrophoneSilenceMonitor(startTime: monotonicSeconds())
        microphoneSilenceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let silence = self.microphoneSilence else { return }
                let isSilent = silence.isSilent(at: monotonicSeconds())
                guard isSilent != self.isShowingSilentMicrophone else { return }
                self.isShowingSilentMicrophone = isSilent
                dictationLog.notice("microphone \(isSilent ? "went silent" : "signal returned")")
                if isSilent {
                    self.headsUpDisplay.showSilentMicrophone()
                } else {
                    self.headsUpDisplay.resumeListening()
                }
            }
        }
    }

    private func stopWatchingForSilentMicrophone() {
        microphoneSilenceTimer?.invalidate()
        microphoneSilenceTimer = nil
        microphoneSilence = nil
        isShowingSilentMicrophone = false
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
        let clipboardChangeCount = NSPasteboard.general.changeCount
        let held = recorder.elapsed
        let audioSeconds = recorder.finish()
        let stopTime = Date()
        recording.streaming.stop()
        headsUpDisplay.showTranscribing(waitingForResult: recording.streaming.beganDuringLoading)
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
        let lifecycle = DeliveryLifecycle(predecessor: previous)
        let task = Task { [weak self] in
            let result: StreamingTranscriptionResult
            do {
                result = try await streaming.finish()
            } catch {
                guard let self, self.deliveries[identifier] != nil, !Task.isCancelled else { return }
                await previous?.waitUntilFinished()
                guard self.deliveries[identifier] != nil, !Task.isCancelled else { return }
                NSSound.beep()
                self.finishDelivery(identifier, outcome: .refused(error.localizedDescription))
                return
            }
            guard let self, self.deliveries[identifier] != nil, !Task.isCancelled else {
                dictationLog.notice("transcription finished after cancellation; discarded")
                return
            }
            dictationLog.notice("transcribed \(result.chunkCount) windows, \(String(format: "%.1f", result.transcribedSeconds)) s of model input from \(String(format: "%.1f", result.audioSeconds)) s recorded: \(result.text.count) characters, stop to result \(String(format: "%.3f", Date().timeIntervalSince(stopTime))) s, of which model \(String(format: "%.3f", result.processingSecondsAfterEnd)) s")
            self.deliveries[identifier]?.result = result
            lifecycle.armDeadline(after: DeliveryLifecycle.insertionTimeout) { [weak self] in
                self?.deliveryTimedOut(identifier)
            }
            await previous?.waitUntilFinished()
            guard self.deliveries[identifier] != nil, !Task.isCancelled else { return }
            if let interruption, result.text.isEmpty {
                self.finishDelivery(identifier, outcome: .refused(interruption.localizedDescription))
                return
            }
            await self.deliver(result.text, audioSeconds: result.audioSeconds, target: target, delivery: identifier,
                               recovery: interruption != nil ? .microphoneDisconnected : streaming.requiresRecovery ? .modelUnavailable : nil,
                               clipboardChangeCount: clipboardChangeCount)
        }
        deliveries[identifier] = Delivery(appearance: headsUpDisplay.stoppedAppearance, task: task, streaming: streaming,
                                          lifecycle: lifecycle, target: target, clipboardChangeCount: clipboardChangeCount)
        latestDelivery = lifecycle
        lifecycle.armDeadline(after: DeliveryLifecycle.transcriptionTimeout) { [weak self] in
            self?.deliveryTimedOut(identifier)
        }
        updatePhase()
        updateHeadsUpDisplay()
    }

    private func makeStream(recording identifier: UUID) -> StreamingTranscription? {
        model.makeStreamingTranscription(onActivity: { [weak self] activity in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.speechActivityChanged(activity, recording: identifier) }
            }
        })
    }

    private func modelReadinessChanged() {
        var pending = deliveries.map { ($0.key, $0.value.streaming) }
        if let recording { pending.append((recording.identifier, recording.streaming)) }
        for (identifier, transcription) in pending where transcription.needsModel {
            if model.isReady, let stream = makeStream(recording: identifier) { transcription.modelReady(stream) }
            else if case .failed = model.state { transcription.modelUnavailable() }
        }
        if recording == nil { updateHeadsUpDisplay() }
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
    private func deliver(_ rawText: String, audioSeconds: Double, target: InsertionTarget?, delivery: UUID,
                         recovery: DictationMiss? = nil, clipboardChangeCount: Int) async {
        guard !rawText.isEmpty else {
            finishDelivery(delivery, outcome: .refused("No speech was recognized."))
            return
        }
        let prepared = pipeline.prepare(rawText, bundleIdentifier: target?.bundleIdentifier)
        guard deliveries[delivery] != nil, !Task.isCancelled else { return }
        guard prepared.profile.producesText else {
            finishDelivery(delivery, outcome: .refused("Dictation is turned off in \(target?.applicationName ?? "this application")."))
            return
        }
        let text = prepared.finalText
        guard !text.isEmpty else {
            finishDelivery(delivery, outcome: .refused("No text remained after text processing."))
            return
        }
        if target?.wasSecure == true {
            showMiss(text, reason: .secureField, clipboard: .preserve, delivery: delivery)
            return
        }
        // History and transcript files are written after insertion, and never for text a password field refused.
        let record = {
            await self.pipeline.record(
                rawText: rawText, finalText: text, durationSeconds: audioSeconds, applicationName: target?.applicationName,
                bundleIdentifier: target?.bundleIdentifier, style: prepared.profile)
        }
        if let recovery {
            if let target, target.focusedElement.map({
                Accessibility.describe($0, processIdentifier: target.processIdentifier).isSecure
            }) == true {
                showMiss(text, reason: .secureField, clipboard: .preserve, delivery: delivery)
                return
            }
            lastTranscript = text
            showMiss(text, reason: recovery, clipboard: .writeIfUnchanged(changeCount: clipboardChangeCount), delivery: delivery)
            if recovery != .microphoneDisconnected { await record() }
            return
        }
        guard let target else {
            lastTranscript = text
            showMiss(text, reason: .noTextField, clipboard: .writeIfUnchanged(changeCount: clipboardChangeCount), delivery: delivery)
            await record()
            return
        }
        let outcome = await TextInserter.insert(text, into: target, clipboardChangeCount: clipboardChangeCount, onLanded: { [weak self] in self?.deliveryLanded(delivery) })
        guard deliveries[delivery] != nil else { return }
        // Finish the dictation first, then write history: the write is the last suspension and touches no session state.
        switch outcome {
        case .inserted(let method):
            finishDelivery(delivery, outcome: .inserted(application: target.applicationName, method: method, profile: prepared.profile.rawValue))
        case .refusedSecureField:
            showMiss(text, reason: .secureField, clipboard: .preserve, delivery: delivery)
        case .noEditableFocus:
            showMiss(text, reason: .noTextField, clipboard: .writeIfUnchanged(changeCount: clipboardChangeCount), delivery: delivery)
        case .targetChanged:
            showMiss(text, reason: .focusMoved, clipboard: .writeIfUnchanged(changeCount: clipboardChangeCount), delivery: delivery)
        case .unconfirmed(let clipboard):
            showMiss(text, reason: .unconfirmed, clipboard: clipboard, delivery: delivery)
        case .cancelled:
            finishDelivery(delivery, outcome: .refused("Dictation was cancelled."))
            return
        }
        switch outcome {
        case .refusedSecureField, .cancelled:
            break
        case .inserted, .noEditableFocus, .targetChanged, .unconfirmed:
            // A short or empty recording must not erase the last usable transcript.
            lastTranscript = text
            await record()
        }
    }

    private func showMiss(_ text: String, reason: DictationMiss, clipboard: ClipboardFallback, delivery: UUID) {
        guard let pending = deliveries[delivery] else { return }
        let recovery = DictationClipboardRecovery.prepare(text, reason: reason, clipboard: clipboard,
                                                          stoppedChangeCount: pending.clipboardChangeCount)
        // Freeze the visible frame before finishing delivery can redraw the ordinary stop animation.
        headsUpDisplay.showPark(reason: recovery.reason, appearance: pending.appearance, clipboardChangeCount: recovery.changeCount,
                                pasteShortcut: settings.configuration.repasteChord?.displayName)
        finishDelivery(delivery, outcome: recovery.reason == .secureField
                       ? .refused(recovery.reason.completionMessage) : .parked(recovery.reason))
    }

    private func deliveryTimedOut(_ identifier: UUID) {
        guard let delivery = deliveries[identifier] else { return }
        if let result = delivery.result {
            let prepared = pipeline.prepare(result.text, bundleIdentifier: delivery.target?.bundleIdentifier)
            if delivery.target?.wasSecure == true || delivery.target?.focusedElement.map({
                Accessibility.describe($0, processIdentifier: delivery.target!.processIdentifier).isSecure
            }) == true {
                showMiss("", reason: .secureField, clipboard: .preserve, delivery: identifier)
            } else if !prepared.profile.producesText {
                finishDelivery(identifier, outcome: .refused("Dictation is turned off in \(delivery.target?.applicationName ?? "this application")."))
            } else if prepared.finalText.isEmpty {
                finishDelivery(identifier, outcome: .refused("No speech was recognized."))
            } else {
                lastTranscript = prepared.finalText
                showMiss(prepared.finalText, reason: .deliveryTimedOut,
                         clipboard: .writeIfUnchanged(changeCount: delivery.clipboardChangeCount), delivery: identifier)
            }
        } else {
            showMiss("", reason: .transcriptionTimedOut, clipboard: .preserve, delivery: identifier)
        }
        delivery.task.cancel()
        delivery.streaming.cancel()
    }

    /// Text delivery does not shorten the indicator's smoke or disturb a newer recording.
    private func deliveryLanded(_ delivery: UUID) {
        guard briefDisplayIdentifier == nil, recording == nil, deliveries.count == 1, deliveries[delivery] != nil else { return }
        headsUpDisplay.hide()
    }

    private func updatePhase() {
        phase = recording != nil ? .recording : deliveries.isEmpty ? .idle : .transcribing
    }

    private func updateHeadsUpDisplay() {
        guard briefDisplayIdentifier == nil || phase == .recording else { return }
        switch phase {
        case .idle: headsUpDisplay.hide()
        case .recording: headsUpDisplay.showListening(on: NSScreen.screenWithMouse())
        case .transcribing:
            let active = deliveries.values.filter { $0.streaming.state != .retained }
            if active.isEmpty { headsUpDisplay.hide() }
            else { headsUpDisplay.showTranscribing(waitingForResult: active.contains { $0.streaming.beganDuringLoading }) }
        }
    }

    /// Ends the recording without touching earlier dictations that are still transcribing.
    private func endRecording() {
        stopWatchingForSilentMicrophone()
        recording = nil
        hotkeys.resetSession()
        updatePhase()
    }

    private func finishDelivery(_ delivery: UUID, outcome: DeliveryLifecycle.Outcome) {
        guard let pending = deliveries.removeValue(forKey: delivery), pending.lifecycle.finish(outcome) else { return }
        lastMessage = outcome.message
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
            recorder.finish()
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
        let cancelled = deliveries
        for (identifier, delivery) in cancelled {
            finishDelivery(identifier, outcome: .refused("Dictation was cancelled."))
            delivery.task.cancel()
            delivery.streaming.cancel()
        }
        updatePhase()
    }



}
