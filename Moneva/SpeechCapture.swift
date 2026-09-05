@preconcurrency import AVFoundation
import Foundation
import Speech

/// Live microphone transcription, fully on device. Holds no money logic — it
/// only produces the sentence the drafter reads.
@MainActor
@Observable
final class SpeechCapture {
    private(set) var finalized = ""
    private(set) var volatile = ""
    private(set) var isRecording = false
    private(set) var error: String?

    private var starting = false
    private var tapInstalled = false
    private var generation = UUID()
    private var resultGeneration = UUID()
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    var text: String {
        (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func start() async {
        guard !isRecording && !starting else { return }
        starting = true
        let token = UUID()
        generation = token
        resultGeneration = token
        defer { if generation == token { starting = false } }
        error = nil
        finalized = ""
        volatile = ""

        guard await Self.requestPermissions() else {
            error = "Moneva needs the microphone and speech recognition to listen."
            return
        }
        guard generation == token, !Task.isCancelled else { return }
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            error = "Speech recognition is not available for your language."
            return
        }

        guard generation == token, !Task.isCancelled else { return }
        do {
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            self.transcriber = transcriber

            // Assets live outside the bundle; the system shares one copy.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }

            guard generation == token, !Task.isCancelled else { return }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer

            guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                error = "No compatible audio format for transcription."
                return
            }

            guard generation == token, !Task.isCancelled else { return }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let (inputSequence, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
            inputBuilder = builder

            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self, self.resultGeneration == token else { return }
                        if result.isFinal {
                            self.volatile = ""
                            self.finalized += String(result.text.characters)
                        } else {
                            self.volatile = String(result.text.characters)
                        }
                    }
                } catch {
                    if self?.resultGeneration == token { self?.error = "Transcription stopped: \(error.localizedDescription)" }
                }
            }

            let inputNode = engine.inputNode
            let tapFormat = inputNode.outputFormat(forBus: 0)
            let converter = tapFormat == analyzerFormat ? nil : AVAudioConverter(from: tapFormat, to: analyzerFormat)
            guard tapFormat == analyzerFormat || converter != nil else {
                error = "Could not convert microphone audio. Type your request instead."
                await stop()
                return
            }
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
                guard let ready = Self.convert(buffer, with: converter, to: analyzerFormat) else { return }
                builder.yield(AnalyzerInput(buffer: ready))
            }

            tapInstalled = true
            engine.prepare()
            try engine.start()
            try await analyzer.start(inputSequence: inputSequence)
            guard generation == token, !Task.isCancelled else { return }
            isRecording = true
        } catch {
            guard generation == token else { return }
            self.error = "Could not start listening: \(error.localizedDescription)"
            await stop()
        }
    }

    func stop() async {
        let token = UUID()
        generation = token
        starting = false
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        inputBuilder?.finish()
        inputBuilder = nil
        let finishing = analyzer
        let results = resultsTask
        analyzer = nil
        resultsTask = nil
        transcriber = nil
        isRecording = false
        do { try await finishing?.finalizeAndFinishThroughEndOfInput() }
        catch { results?.cancel() }
        await results?.value
        guard generation == token else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// Runs on the audio thread. The analyzer wants its own sample rate, and
    /// the input node rarely matches it.
    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter?, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return conversionError == nil && output.frameLength > 0 ? output : nil
    }
}
