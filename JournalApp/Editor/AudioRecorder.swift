import AVFoundation
import Observation

/// Records one voice memo to a temporary AAC file (44.1 kHz mono, per the spec).
@MainActor
@Observable
final class AudioRecorder {
    enum State { case idle, recording, paused }

    private(set) var state = State.idle
    private(set) var elapsed: TimeInterval = 0
    /// Recent input levels from 0 to 1, oldest first, for the live level bars.
    private(set) var levels: [Float] = Array(repeating: 0, count: AudioRecorder.levelCount)
    private(set) var startedAt: Date?

    static let levelCount = 40

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    let fileURL = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")

    enum RecorderError: Error, LocalizedError {
        case couldNotStart

        var errorDescription: String? {
            String(localized: "Recording couldn't start. Another app may be using the microphone.")
        }
    }

    enum Permission { case granted, denied }

    /// Asks for microphone access the first time. Returns whether recording is allowed.
    static func requestPermission() async -> Permission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return await AVAudioApplication.requestRecordPermission() ? .granted : .denied
        }
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw RecorderError.couldNotStart }
        self.recorder = recorder
        startedAt = .now
        state = .recording
        startMetering()
    }

    func pause() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused, recorder?.record() == true else { return }
        state = .recording
    }

    /// Finishes the recording and returns its file, or nil if nothing was recorded.
    func finish() -> URL? {
        guard let recorder else { return nil }
        elapsed = recorder.currentTime
        recorder.stop()
        tearDown()
        return elapsed > 0.3 ? fileURL : nil
    }

    /// Stops and throws the recording away.
    func discard() {
        recorder?.stop()
        recorder?.deleteRecording()
        tearDown()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func tearDown() {
        meterTask?.cancel()
        meterTask = nil
        recorder = nil
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sample()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func sample() {
        guard let recorder else { return }
        elapsed = recorder.currentTime
        guard state == .recording else { return }
        recorder.updateMeters()
        // Decibels (-160 to 0) to 0...1, with the quiet end trimmed so speech fills the bars.
        let power = recorder.averagePower(forChannel: 0)
        let level = max(0, min(1, (power + 50) / 50))
        levels.removeFirst()
        levels.append(level)
    }
}
