import AppKit
import AVFoundation
import CoreAudio
import Foundation

enum AudioMode: String, CaseIterable, Identifiable {
    case live = "Live"
    case record = "Record"

    var id: String { rawValue }
}

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

final class AudioEngineController: ObservableObject {
    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var selectedInputDeviceID: AudioDeviceID = 0
    @Published private(set) var selectedOutputDeviceID: AudioDeviceID = 0

    @Published private(set) var statusMessage = "Initializing audio engine..."
    @Published private(set) var isRunning = false
    @Published private(set) var lastRecordingPath = ""
    @Published private(set) var mode: AudioMode = .live
    @Published private(set) var autotuneAmount: Double = 60
    @Published private(set) var reverbAmount: Double = 20

    private let engine = AVAudioEngine()
    private let preFXMixer = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let reverb = AVAudioUnitReverb()
    private let pitchDetector = PitchDetector()

    private var graphConfigured = false
    private var activeGraphMode: GraphMode = .mixerAutotune
    private var recordingFile: AVAudioFile?
    private let recordingsFolderURL: URL

    private enum GraphMode: String {
        case mixerAutotune = "Autotune + Reverb"
        case directAutotune = "Autotune + Reverb (Direct)"
        case reverbOnly = "Reverb Only"
        case dry = "Dry"

        var hasAutotune: Bool {
            switch self {
            case .mixerAutotune, .directAutotune:
                return true
            case .reverbOnly, .dry:
                return false
            }
        }

        var hasReverb: Bool {
            switch self {
            case .mixerAutotune, .directAutotune, .reverbOnly:
                return true
            case .dry:
                return false
            }
        }
    }

    init() {
        let musicFolder = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        recordingsFolderURL = musicFolder.appendingPathComponent("AutoTuneLiveRecordings", isDirectory: true)

        configureNodes()
        refreshDevices()
        statusMessage = "Ready. Waiting for microphone permission..."
    }

    func startIfPossible() {
        if isRunning {
            return
        }
        requestMicrophonePermissionAndStart()
    }

    func toggleStartStop() {
        if isRunning {
            stopEngine()
        } else {
            startIfPossible()
        }
    }

    func refreshDevices() {
        let discoveredDevices = Self.fetchAudioDevices()
        let nextInputDevices = discoveredDevices
            .filter { $0.inputChannels > 0 }
            .map { AudioDevice(id: $0.id, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let nextOutputDevices = discoveredDevices
            .filter { $0.outputChannels > 0 }
            .map { AudioDevice(id: $0.id, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        inputDevices = nextInputDevices
        outputDevices = nextOutputDevices

        let defaultInput = Self.defaultDeviceID(isInput: true)
        let defaultOutput = Self.defaultDeviceID(isInput: false)

        selectedInputDeviceID = resolveSelection(
            current: selectedInputDeviceID,
            fallback: defaultInput,
            available: nextInputDevices
        )

        selectedOutputDeviceID = resolveSelection(
            current: selectedOutputDeviceID,
            fallback: defaultOutput,
            available: nextOutputDevices
        )
    }

    func selectInputDevice(id: AudioDeviceID) {
        guard id != 0, id != selectedInputDeviceID else {
            return
        }

        if Self.setDefaultDeviceID(id: id, isInput: true) {
            selectedInputDeviceID = id
            restartEngineForDeviceChange()
            statusMessage = "Input switched to \(deviceName(for: id, from: inputDevices))."
        } else {
            statusMessage = "Could not switch input device."
            refreshDevices()
        }
    }

    func selectOutputDevice(id: AudioDeviceID) {
        guard id != 0, id != selectedOutputDeviceID else {
            return
        }

        if Self.setDefaultDeviceID(id: id, isInput: false) {
            selectedOutputDeviceID = id
            restartEngineForDeviceChange()
            statusMessage = "Output switched to \(deviceName(for: id, from: outputDevices))."
        } else {
            statusMessage = "Could not switch output device."
            refreshDevices()
        }
    }

    func setMode(_ nextMode: AudioMode) {
        guard mode != nextMode else {
            return
        }

        mode = nextMode
        updateRecordingTap()

        if isRunning {
            statusMessage = mode == .record
                ? "Recording active."
                : "Live monitoring active."
        }
    }

    func setAutotuneAmount(_ amount: Double) {
        autotuneAmount = amount.clamped(to: 0 ... 100)
    }

    func setReverbAmount(_ amount: Double) {
        reverbAmount = amount.clamped(to: 0 ... 100)
        reverb.wetDryMix = Float(reverbAmount)
    }

    func openRecordingsFolder() {
        do {
            try FileManager.default.createDirectory(at: recordingsFolderURL, withIntermediateDirectories: true)
            NSWorkspace.shared.open(recordingsFolderURL)
        } catch {
            statusMessage = "Could not open recordings folder: \(error.localizedDescription)"
        }
    }

    private func requestMicrophonePermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngine()
        case .notDetermined:
            statusMessage = "Requesting microphone permission..."
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.startEngine()
                    } else {
                        self.statusMessage = "Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone."
                    }
                }
            }
        case .denied, .restricted:
            statusMessage = "Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone."
        @unknown default:
            statusMessage = "Microphone permission is unavailable on this system."
        }
    }

    private func startEngine() {
        let modesToTry: [GraphMode] = [.mixerAutotune, .directAutotune, .reverbOnly, .dry]
        var lastError: Error?

        for graphMode in modesToTry {
            do {
                try configureGraph(mode: graphMode)
                engine.prepare()
                try engine.start()
                isRunning = true
                activeGraphMode = graphMode
                updateRecordingTap()

                if mode == .record {
                    statusMessage = statusTextForRunningMode(graphMode, recording: true)
                } else {
                    statusMessage = statusTextForRunningMode(graphMode, recording: false)
                }
                return
            } catch {
                lastError = error
                engine.stop()
            }
        }

        isRunning = false
        statusMessage = "Failed to start audio engine: \(lastError?.localizedDescription ?? "Unknown error")"
    }

    private func stopEngine() {
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.inputNode.removeTap(onBus: 0)
        recordingFile = nil
        engine.stop()
        isRunning = false
        statusMessage = "Stopped."
    }

    private func restartEngineForDeviceChange() {
        guard isRunning else {
            return
        }

        stopEngine()
        requestMicrophonePermissionAndStart()
    }

    private func configureNodes() {
        preFXMixer.outputVolume = 1.0
        timePitch.rate = 1.0
        timePitch.overlap = 8.0
        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = Float(reverbAmount)
    }

    private func configureGraph(mode graphMode: GraphMode) throws {
        if !graphConfigured {
            engine.attach(preFXMixer)
            engine.attach(timePitch)
            engine.attach(reverb)
            graphConfigured = true
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        if inputFormat.channelCount == 0 {
            throw AudioEngineError.noInputChannels
        }

        inputNode.removeTap(onBus: 0)

        engine.disconnectNodeOutput(inputNode)
        engine.disconnectNodeOutput(preFXMixer)
        engine.disconnectNodeInput(preFXMixer)
        engine.disconnectNodeOutput(timePitch)
        engine.disconnectNodeInput(timePitch)
        engine.disconnectNodeOutput(reverb)
        engine.disconnectNodeInput(reverb)

        switch graphMode {
        case .mixerAutotune:
            engine.connect(inputNode, to: preFXMixer, format: nil)
            engine.connect(preFXMixer, to: timePitch, format: nil)
            engine.connect(timePitch, to: reverb, format: nil)
            engine.connect(reverb, to: engine.mainMixerNode, format: nil)
        case .directAutotune:
            engine.connect(inputNode, to: timePitch, format: nil)
            engine.connect(timePitch, to: reverb, format: nil)
            engine.connect(reverb, to: engine.mainMixerNode, format: nil)
        case .reverbOnly:
            engine.connect(inputNode, to: reverb, format: nil)
            engine.connect(reverb, to: engine.mainMixerNode, format: nil)
        case .dry:
            engine.connect(inputNode, to: engine.mainMixerNode, format: nil)
        }

        if graphMode.hasAutotune {
            installPitchTap(on: inputNode, format: inputFormat)
        } else {
            inputNode.removeTap(onBus: 0)
        }

        timePitch.pitch = 0
        reverb.wetDryMix = graphMode.hasReverb ? Float(reverbAmount) : 0
    }

    private func installPitchTap(on inputNode: AVAudioInputNode, format: AVAudioFormat) {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let frequency = self.pitchDetector.estimateFrequency(from: buffer) else {
                self.timePitch.pitch = 0
                return
            }

            let correctionCents = Self.correctionCentsToNearestSemitone(frequency: frequency)
            let blend = Float(self.autotuneAmount / 100)
            self.timePitch.pitch = correctionCents * blend
        }
    }

    private func updateRecordingTap() {
        engine.mainMixerNode.removeTap(onBus: 0)
        recordingFile = nil

        guard isRunning, mode == .record else {
            return
        }

        do {
            try FileManager.default.createDirectory(at: recordingsFolderURL, withIntermediateDirectories: true)

            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            let fileURL = makeRecordingURL()
            recordingFile = try AVAudioFile(forWriting: fileURL, settings: format.settings)

            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let self, let file = self.recordingFile else { return }
                do {
                    try file.write(from: buffer)
                } catch {
                    DispatchQueue.main.async {
                        self.statusMessage = "Recording error: \(error.localizedDescription)"
                    }
                }
            }

            lastRecordingPath = fileURL.path
            statusMessage = statusTextForRunningMode(activeGraphMode, recording: true)
        } catch {
            statusMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    private func statusTextForRunningMode(_ graphMode: GraphMode, recording: Bool) -> String {
        switch graphMode {
        case .mixerAutotune, .directAutotune:
            return recording
                ? "Recording active (\(graphMode.rawValue))."
                : "Live monitoring active (\(graphMode.rawValue))."
        case .reverbOnly:
            return recording
                ? "Recording active (Reverb only fallback; autotune unavailable on this device format)."
                : "Live monitoring active (Reverb only fallback; autotune unavailable on this device format)."
        case .dry:
            return recording
                ? "Recording active (Dry fallback; effects unavailable on this device format)."
                : "Live monitoring active (Dry fallback; effects unavailable on this device format)."
        }
    }

    private func makeRecordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        return recordingsFolderURL.appendingPathComponent("autotune-\(stamp).caf")
    }

    private func resolveSelection(
        current: AudioDeviceID,
        fallback: AudioDeviceID?,
        available: [AudioDevice]
    ) -> AudioDeviceID {
        if available.contains(where: { $0.id == current }) {
            return current
        }

        if let fallback, available.contains(where: { $0.id == fallback }) {
            return fallback
        }

        return available.first?.id ?? 0
    }

    private func deviceName(for id: AudioDeviceID, from devices: [AudioDevice]) -> String {
        devices.first(where: { $0.id == id })?.name ?? "Device \(id)"
    }

    private static func correctionCentsToNearestSemitone(frequency: Float) -> Float {
        guard frequency > 0 else {
            return 0
        }

        let midiNote = 69.0 + 12.0 * log2(Double(frequency) / 440.0)
        let targetMidi = round(midiNote)
        let targetFrequency = 440.0 * pow(2.0, (targetMidi - 69.0) / 12.0)
        let cents = 1200.0 * log2(targetFrequency / Double(frequency))

        if cents.isFinite {
            return Float(cents).clamped(to: -1200 ... 1200)
        }

        return 0
    }

    private struct HardwareDevice {
        let id: AudioDeviceID
        let name: String
        let inputChannels: Int
        let outputChannels: Int
    }

    private static func fetchAudioDevices() -> [HardwareDevice] {
        allDeviceIDs().map { id in
            HardwareDevice(
                id: id,
                name: deviceName(for: id),
                inputChannels: channelCount(for: id, scope: kAudioDevicePropertyScopeInput),
                outputChannels: channelCount(for: id, scope: kAudioDevicePropertyScopeOutput)
            )
        }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let success = ids.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return false
            }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                baseAddress
            ) == noErr
        }
        guard success else {
            return []
        }

        return ids
    }

    private static func deviceName(for id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: CFString = "Unknown Device" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        if status == noErr {
            return name as String
        }
        return "Device \(id)"
    }

    private static func channelCount(for id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else {
            return 0
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, rawPointer) == noErr else {
            return 0
        }

        let audioBufferList = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func defaultDeviceID(isInput: Bool) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: isInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)

        return status == noErr ? id : nil
    }

    private static func setDefaultDeviceID(id: AudioDeviceID, isInput: Bool) -> Bool {
        var mutableID = id

        var outputAddress = AudioObjectPropertyAddress(
            mSelector: isInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let primarySet = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &outputAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableID
        ) == noErr

        if !primarySet {
            return false
        }

        if !isInput {
            // Keep system sounds and app output aligned with user selection.
            var systemOutputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            _ = AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &systemOutputAddress,
                0,
                nil,
                UInt32(MemoryLayout<AudioDeviceID>.size),
                &mutableID
            )
        }

        return true
    }
}

private enum AudioEngineError: Error, LocalizedError {
    case noInputChannels

    var errorDescription: String? {
        switch self {
        case .noInputChannels:
            return "Selected microphone has no available input channels."
        }
    }
}

private final class PitchDetector {
    private let minFrequency: Float = 70
    private let maxFrequency: Float = 1_000
    private let levelThreshold: Float = 0.01

    func estimateFrequency(from buffer: AVAudioPCMBuffer) -> Float? {
        guard let channelData = buffer.floatChannelData else {
            return nil
        }

        let frameCount = Int(buffer.frameLength)
        if frameCount < 512 {
            return nil
        }

        let input = channelData[0]
        var samples = [Float](repeating: 0, count: frameCount)
        for index in 0 ..< frameCount {
            samples[index] = input[index]
        }

        var mean: Float = 0
        for sample in samples {
            mean += sample
        }
        mean /= Float(frameCount)

        var energy: Float = 0
        for index in 0 ..< frameCount {
            samples[index] -= mean
            energy += samples[index] * samples[index]
        }

        let rms = sqrt(energy / Float(frameCount))
        if rms < levelThreshold {
            return nil
        }

        let sampleRate = Float(buffer.format.sampleRate)
        let minLag = max(1, Int(sampleRate / maxFrequency))
        let maxLag = min(frameCount - 2, Int(sampleRate / minFrequency))

        if maxLag <= minLag {
            return nil
        }

        var bestLag = minLag
        var bestCorrelation: Float = 0

        for lag in minLag ... maxLag {
            let upperBound = frameCount - lag
            var correlation: Float = 0
            var lagEnergy: Float = 0

            for index in 0 ..< upperBound {
                let a = samples[index]
                let b = samples[index + lag]
                correlation += a * b
                lagEnergy += a * a + b * b
            }

            if lagEnergy > 0 {
                correlation /= lagEnergy
            }

            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestLag = lag
            }
        }

        if bestCorrelation < 0.1 {
            return nil
        }

        let frequency = sampleRate / Float(bestLag)
        if frequency.isFinite, frequency >= minFrequency, frequency <= maxFrequency {
            return frequency
        }

        return nil
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
