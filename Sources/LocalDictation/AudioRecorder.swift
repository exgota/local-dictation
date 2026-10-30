import AVFoundation
import CoreAudio
import Foundation
import os

struct AudioInputDevice: Identifiable, Hashable {
    let identifier: String
    let name: String
    var id: String { identifier }

    static func all() -> [AudioInputDevice] {
        allDeviceIdentifiers().compactMap { deviceID in
            guard inputChannelCount(deviceID) > 0,
                let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID),
                let name = stringProperty(deviceID, kAudioObjectPropertyName),
                // Core Audio's private aggregate for default input and output is not a microphone.
                !uid.hasPrefix("CADefaultDeviceAggregate")
            else { return nil }
            return AudioInputDevice(identifier: uid, name: name)
        }
    }

    static func deviceID(forIdentifier identifier: String) -> AudioDeviceID? {
        allDeviceIdentifiers().first { stringProperty($0, kAudioDevicePropertyDeviceUID) == identifier && inputChannelCount($0) > 0 }
    }

    private static func allDeviceIdentifiers() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var identifiers = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &identifiers) == noErr
        else { return [] }
        return identifiers
    }

    private static func inputChannelCount(_ device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// The current input devices. The list refreshes whenever Core Audio reports that a device was added or removed.
@MainActor final class AudioInputDeviceCatalog: ObservableObject {
    @Published private(set) var devices = AudioInputDevice.all()
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var listener: AudioObjectPropertyListenerBlock?

    init() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.devices = AudioInputDevice.all() }
        }
        self.listener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }

    func name(for identifier: String?) -> String {
        guard let identifier else { return "System default" }
        return devices.first { $0.identifier == identifier }?.name ?? "Unavailable microphone"
    }
}

enum AudioRecorderError: LocalizedError {
    case inputUnavailable
    case selectedDeviceUnavailable
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .inputUnavailable: return "No microphone input is available."
        case .selectedDeviceUnavailable: return "The selected microphone is not available. Choose another in Settings."
        case .converterUnavailable: return "The microphone format cannot be converted to 16 kHz."
        }
    }
}

/// Captures the selected microphone as mono 16 kHz Float32 through `AVCaptureSession`, which selects the device by its
/// Core Audio UID and converts the format itself.
///
/// The microphone is open only while recording. The recorder passes audio straight to the consumer and writes nothing
/// to disk.
@MainActor final class AudioRecorder {
    /// Microphone RMS level in dBFS (-140...0), delivered on the main thread about every 20 ms while recording.
    var onLevel: (Float) -> Void = { _ in }
    /// Called when the maximum duration passed to `start` is reached; a watchdog for missed key-ups.
    var onMaximumDurationReached: () -> Void = {}
    /// Called when capture ends on its own: the session did not start running, the selected microphone disappeared, or
    /// capture could not be restarted. The audio delivered so far is complete up to that point.
    var onCaptureInterrupted: (Error) -> Void = { _ in }

    private let router = SampleRouter()
    private let sampleDelegate: SampleBufferReceiver
    private let captureQueue = DispatchQueue(label: "LocalDictation.AudioCapture", qos: .userInteractive)
    private var session: AVCaptureSession?
    /// The selection the running session was started for: nil means no session is running, and `.some(nil)` means the
    /// system default.
    private var sessionSelection: String??
    private var observers: [NSObjectProtocol] = []
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var startTime: TimeInterval = 0
    private var durationTimer: Timer?
    /// Capture restarts in the current recording. A microphone that keeps failing ends the recording after
    /// `maximumRestarts` restarts.
    private var restartCount = 0
    private static let maximumRestarts = 3

    private(set) var isRecording = false

    init() {
        sampleDelegate = SampleBufferReceiver(router: router)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.defaultInputChanged() } }
        }
        defaultDeviceListener = listener
        var address = Self.defaultInputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }

    /// `onFirstAudio` runs on the main actor once the microphone delivers its first samples, which can be half a second
    /// after this call.
    func start(
        deviceIdentifier: String?, maximumDuration: TimeInterval, consumer: @escaping @Sendable ([Float]) -> Void,
        onFirstAudio: @escaping @MainActor () -> Void
    ) throws {
        if isRecording { cancel() }
        stopSession()
        restartCount = 0
        try startSession(deviceIdentifier: deviceIdentifier)
        router.beginRecording(
            consumer: consumer,
            level: { [weak self] level in DispatchQueue.main.async { MainActor.assumeIsolated { self?.onLevel(level) } } },
            firstAudio: { delay in
                dictationLog.notice("microphone delivered first audio after \(String(format: "%.3f", delay)) s")
                DispatchQueue.main.async { MainActor.assumeIsolated { onFirstAudio() } }
            })
        isRecording = true
        startTime = ProcessInfo.processInfo.systemUptime
        durationTimer = Timer.scheduledTimer(withTimeInterval: maximumDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.onMaximumDurationReached() }
        }
    }

    /// Stops recording and closes the microphone. Returns the recorded duration in seconds.
    @discardableResult
    func finish() -> TimeInterval {
        let samples = router.endRecording()
        durationTimer?.invalidate()
        durationTimer = nil
        isRecording = false
        stopSession()
        return Double(samples) / 16_000
    }

    func cancel() {
        finish()
    }

    /// Seconds since `start` while recording, 0 otherwise.
    var elapsed: TimeInterval { isRecording ? ProcessInfo.processInfo.systemUptime - startTime : 0 }

    /// Restarts capture for the current recording after the system wakes, because audio devices may have been reset.
    func restartAfterWake() {
        guard isRecording, let selection = sessionSelection else { return }
        restart(selection: selection)
    }

    /// With "System default" selected, capture follows the default input when it changes.
    private func defaultInputChanged() {
        guard let selection = sessionSelection, selection == nil else { return }
        restart(selection: nil)
    }

    /// Starts again on the same selection. The recorder never substitutes a different microphone: if the selected one
    /// is gone, it reports the interruption, the recording stops and the user is told.
    private func restart(selection: String?) {
        guard isRecording else { return }
        stopSession()
        restartCount += 1
        guard restartCount <= Self.maximumRestarts else {
            dictationLog.error("microphone failed \(restartCount) times in one recording; stopping")
            onCaptureInterrupted(AudioRecorderError.inputUnavailable)
            return
        }
        do {
            try startSession(deviceIdentifier: selection)
        } catch {
            onCaptureInterrupted(error)
        }
    }

    private func startSession(deviceIdentifier: String?) throws {
        let device: AVCaptureDevice
        if let deviceIdentifier {
            guard let selected = AVCaptureDevice(uniqueID: deviceIdentifier) else { throw AudioRecorderError.selectedDeviceUnavailable }
            device = selected
        } else {
            guard let systemDefault = AVCaptureDevice.default(for: .audio) else { throw AudioRecorderError.inputUnavailable }
            device = systemDefault
        }
        let session = AVCaptureSession()
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw deviceIdentifier == nil ? AudioRecorderError.inputUnavailable : AudioRecorderError.selectedDeviceUnavailable
        }
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(sampleDelegate, queue: captureQueue)
        guard session.canAddInput(input), session.canAddOutput(output) else { throw AudioRecorderError.converterUnavailable }
        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        // startRunning blocks until the device runs, over a second the first time after launch. It therefore runs on
        // the capture queue, so the heads-up display appears at once and audio flows as soon as the device is ready.
        // AVCaptureSession is not Sendable, but Apple documents starting and stopping it on a background queue.
        nonisolated(unsafe) let startingSession = session
        captureQueue.async { [weak self] in
            startingSession.startRunning()
            guard !startingSession.isRunning else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.session === startingSession, self.isRecording else { return }
                    self.onCaptureInterrupted(AudioRecorderError.inputUnavailable)
                }
            }
        }
        self.session = session
        sessionSelection = .some(deviceIdentifier)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restart(selection: deviceIdentifier) }
            },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restart(selection: deviceIdentifier) }
            },
        ]
    }

    private func stopSession() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        // Queued behind any pending startRunning on the same serial queue, so a quick start and stop stay ordered.
        if let session {
            nonisolated(unsafe) let stoppingSession = session
            captureQueue.async { stoppingSession.stopRunning() }
        }
        session = nil
        sessionSelection = nil
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }
}

/// Receives 16 kHz mono Float32 sample buffers on the capture queue.
private final class SampleBufferReceiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let router: SampleRouter

    init(router: SampleRouter) {
        self.router = router
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
            let pointer, length >= MemoryLayout<Float>.size
        else { return }
        let samples = pointer.withMemoryRebound(to: Float.self, capacity: length / MemoryLayout<Float>.size) {
            Array(UnsafeBufferPointer(start: $0, count: length / MemoryLayout<Float>.size))
        }
        router.receive(samples, level: Self.decibels(of: samples))
    }

    /// RMS level in dBFS, from -140 for silence to 0 at full scale.
    private static func decibels(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -140 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = (sum / Float(samples.count)).squareRoot()
        return min(20 * log10(max(rms, 1e-7)), 0)
    }
}

/// Routes converted audio from the capture queue to the consumer while recording. The router holds the lock only to
/// read and swap state and calls the consumer outside it.
private final class SampleRouter: @unchecked Sendable {
    private struct State {
        var consumer: (@Sendable ([Float]) -> Void)?
        var level: (@Sendable (Float) -> Void)?
        var recordedSamples = 0
        var beginTime: TimeInterval = 0
        var firstAudio: (@Sendable (TimeInterval) -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// `firstAudio` runs once, with the delay from this call to the first delivered samples.
    func beginRecording(
        consumer: @escaping @Sendable ([Float]) -> Void, level: @escaping @Sendable (Float) -> Void,
        firstAudio: @escaping @Sendable (TimeInterval) -> Void
    ) {
        state.withLock { state in
            state.consumer = consumer
            state.level = level
            state.recordedSamples = 0
            state.beginTime = ProcessInfo.processInfo.systemUptime
            state.firstAudio = firstAudio
        }
    }

    /// Returns the number of samples delivered.
    func endRecording() -> Int {
        state.withLock { state in
            state.consumer = nil
            state.level = nil
            return state.recordedSamples
        }
    }

    func receive(_ samples: [Float], level: Float) {
        let targets = state.withLock { state in
            var firstAudio: (callback: @Sendable (TimeInterval) -> Void, delay: TimeInterval)?
            if state.consumer != nil {
                state.recordedSamples += samples.count
                if let callback = state.firstAudio {
                    firstAudio = (callback, ProcessInfo.processInfo.systemUptime - state.beginTime)
                    state.firstAudio = nil
                }
            }
            return (consumer: state.consumer, level: state.level, firstAudio: firstAudio)
        }
        if let firstAudio = targets.firstAudio { firstAudio.callback(firstAudio.delay) }
        targets.consumer?(samples)
        targets.level?(level)
    }
}
