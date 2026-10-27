import AVFoundation
import Speech
import Combine
import OSLog

@MainActor
final class SpeechRecorder: ObservableObject {
    @Published var transcript = ""
    @Published var level: Double = 0
    @Published var isOnDevice = false
    @Published var status = ""
    var onCheckpoint: ((String) -> Void)?
    private var engine = AVAudioEngine()
    private var feed = SpeechAudioFeed()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var words = SpeechTranscript()
    private var tapInstalled = false
    private var finishing = false
    private var recognitionEnded = false
    private var offlineOnly = false
    private var recoveries = 0
    private var lastFailure: NSError?
    private var lastTextUpdate: TimeInterval = 0
    private var sessionID = UUID()
    private var recognitionID = UUID()
    private var windowTimer: Timer?
    private var rotationTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var rotating = false
    private var requestStartedAt: TimeInterval = 0
    private let logger = Logger(subsystem: "app.shepot.mac", category: "Speech")

    static var microphoneGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var speechGranted: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }
    var failureMessage: String {
        if let lastFailure, lastFailure.code != 1110 {
            return "Служба распознавания Apple прервалась (\(lastFailure.code)). Не удалось получить текст после повторной попытки. Попробуйте ещё раз."
        }
        return "Не удалось разобрать речь. Дождитесь индикатора записи и проверьте уровень микрофона."
    }

    static func authorize() async throws {
        if !microphoneGranted {
            let mic = await AVCaptureDevice.requestAccess(for: .audio)
            guard mic else { throw AppError.message("Разрешите микрофон в Системных настройках → Конфиденциальность и безопасность → Микрофон.") }
        }
        try Task.checkCancellation()
        if !speechGranted {
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard status == .authorized else { throw AppError.message("Разрешите распознавание речи в настройках macOS.") }
        }
        try Task.checkCancellation()
    }

    func start(language: String, offlineOnly: Bool, hints: [String]) throws {
        cancel()
        transcript = ""; words = SpeechTranscript(); level = 0; status = ""
        finishing = false; recoveries = 0; lastFailure = nil
        self.offlineOnly = offlineOnly
        self.hints = Array(hints.prefix(100))
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            throw AppError.message("Распознавание этого языка сейчас недоступно. Проверьте подключение и язык в настройках.")
        }
        guard !offlineOnly || recognizer.supportsOnDeviceRecognition else {
            throw AppError.message("Для этого языка локальное распознавание недоступно. Отключите «Только на устройстве» или выберите другой язык.")
        }
        self.recognizer = recognizer
        // Reusing an engine after a device/service interruption can retain a stale format.
        engine = AVAudioEngine(); feed = SpeechAudioFeed()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AppError.message("Микрофон не найден. Подключите устройство ввода.") }
        beginRecognition(replay: false, local: recognizer.supportsOnDeviceRecognition)
        let id = sessionID, audioFeed = feed
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            audioFeed.append(buffer)
            guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var total: Float = 0
            for i in 0..<Int(buffer.frameLength) { total += channel[i] * channel[i] }
            let rms = sqrt(total / Float(buffer.frameLength))
            let normalized = min(1, max(0, (Double(20 * log10(max(rms, 0.00001))) + 55) / 45))
            Task { @MainActor [weak self] in
                guard self?.sessionID == id else { return }
                self?.level = normalized
            }
        }
        tapInstalled = true
        engine.prepare()
        do { try engine.start() }
        catch { cancel(); throw AppError.message("Не удалось запустить микрофон: \(error.localizedDescription)") }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.finishing, !self.rotating else { return }
                if SpeechWindowPolicy.shouldRotate(bufferedDuration: self.feed.bufferedDuration,
                                                   requestAge: ProcessInfo.processInfo.systemUptime - self.requestStartedAt) {
                    self.rotateSegment()
                }
            }
        }
        windowTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private var hints: [String] = []
    private func beginRecognition(replay: Bool, local: Bool) {
        guard let recognizer else { return }
        recoveryTask?.cancel(); recoveryTask = nil
        recognitionID = UUID()
        feed.detach(); task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true; request.taskHint = .dictation
        request.addsPunctuation = true; request.contextualStrings = hints
        request.requiresOnDeviceRecognition = local
        self.request = request; isOnDevice = local; recognitionEnded = false
        requestStartedAt = ProcessInfo.processInfo.systemUptime
        let id = sessionID, attempt = recognitionID
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.sessionID == id, self.recognitionID == attempt else { return }
                if let result {
                    let before = self.words.text
                    let protected = self.words.accept(result.bestTranscription.formattedString,
                                                      audioStart: result.bestTranscription.segments.first?.timestamp,
                                                      audioEnd: result.bestTranscription.segments.last.map { $0.timestamp + $0.duration },
                                                      audioTimesReliable: result.isFinal || result.speechRecognitionMetadata != nil)
                    self.transcript = self.words.text
                    if protected {
                        self.logger.info("Partial window reset; previous text preserved")
                        self.onCheckpoint?(self.transcript)
                    }
                    if before != self.transcript { self.lastTextUpdate = ProcessInfo.processInfo.systemUptime }
                    if !self.transcript.isEmpty { self.status = "" }
                }
                if let error {
                    self.lastFailure = error as NSError
                    self.recognitionEnded = true
                    self.logger.warning("Recognition interrupted: domain=\(self.lastFailure!.domain, privacy: .public) code=\(self.lastFailure!.code) recovery=\(self.recoveries)")
                    if self.rotating { return }
                    if !self.finishing, self.lastFailure?.code == 1110 {
                        // Silence is a window boundary, not the end of a conversation.
                        self.rotateSegment(); return
                    }
                    if !self.finishing, self.recoveries < 1, self.lastFailure?.code != 1700 {
                        self.recoveries += 1
                        self.words.prepareRecovery()
                        self.status = "Восстанавливаю распознавание. Продолжайте говорить…"
                        self.beginRecognition(replay: true, local: self.offlineOnly)
                    } else {
                        self.feed.detach()
                        if !self.finishing, self.lastFailure?.code != 1700 {
                            self.status = "Восстанавливаю распознавание. Уже написанное сохранено…"
                            self.recoveries += 1
                            let pause = min(5, self.recoveries)
                            self.recoveryTask = Task { @MainActor [weak self] in
                                do { try await Task.sleep(nanoseconds: UInt64(pause) * 1_000_000_000) } catch { return }
                                guard let self, self.sessionID == id, self.recognitionID == attempt,
                                      !self.finishing, !self.rotating else { return }
                                self.recoveryTask = nil
                                self.words.prepareRecovery()
                                self.beginRecognition(replay: true, local: self.offlineOnly)
                            }
                        }
                    }
                } else if result?.isFinal == true {
                    self.recognitionEnded = true
                    if !self.finishing, !self.rotating { self.rotateSegment() }
                }
            }
        }
        feed.attach(request, replay: replay)
    }

    private func rotateSegment() {
        guard !finishing, !rotating else { return }
        rotating = true
        recoveryTask?.cancel(); recoveryTask = nil
        let id = sessionID
        // Microphone capture continues into the next window while the old one finalizes.
        feed.rotate(retaining: SpeechWindowPolicy.overlap)
        task?.finish()
        rotationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = ProcessInfo.processInfo.systemUptime + SpeechWindowPolicy.finalizationGrace
            let earliestRestart = self.requestStartedAt + 0.8
            while (!self.recognitionEnded || ProcessInfo.processInfo.systemUptime < earliestRestart), ProcessInfo.processInfo.systemUptime < deadline {
                do { try await Task.sleep(nanoseconds: 30_000_000) } catch { return }
                guard self.sessionID == id else { return }
            }
            guard self.sessionID == id, !Task.isCancelled else { return }
            self.words.commit(overlapNext: true)
            self.transcript = self.words.text
            self.onCheckpoint?(self.transcript)
            self.recoveries = 0; self.lastFailure = nil; self.rotating = false
            self.beginRecognition(replay: true, local: self.isOnDevice)
            self.rotationTask = nil
            self.logger.info("Recognition window rolled over; microphone kept running")
        }
    }

    func finish() async -> String {
        let id = sessionID
        finishing = true
        recoveryTask?.cancel(); recoveryTask = nil
        windowTimer?.invalidate(); windowTimer = nil
        stopEngine()
        let handover = rotationTask
        if let handover { await handover.value }
        guard sessionID == id, !Task.isCancelled else { return "" }
        let finalReplay = recognitionEnded && lastFailure != nil && lastFailure?.code != 1700 && feed.bufferedDuration > 0
        if finalReplay {
            words.prepareRecovery()
            beginRecognition(replay: true, local: offlineOnly)
        }
        feed.endAudio()
        task?.finish()
        let start = ProcessInfo.processInfo.systemUptime
        let needsDrain = finalReplay || handover != nil || start - requestStartedAt < 2
        // Preserve the latest hypothesis; don't wait a fixed 2.5 seconds for isFinal.
        while !recognitionEnded, !Task.isCancelled, sessionID == id {
            let now = ProcessInfo.processInfo.systemUptime
            let hasActiveText = !words.activeText.isEmpty
            if !needsDrain, hasActiveText, now - start >= 0.4, now - lastTextUpdate >= 0.3 { break }
            if now - start >= (hasActiveText && !needsDrain ? 1.2 : 4.0) { break }
            do { try await Task.sleep(nanoseconds: 30_000_000) } catch { break }
        }
        let text = words.text
        logger.info("Recognition finished: hasText=\(!text.isEmpty) elapsed=\(ProcessInfo.processInfo.systemUptime - start)")
        return text
    }
    func cancel() {
        sessionID = UUID(); recognitionID = UUID(); finishing = true
        windowTimer?.invalidate(); windowTimer = nil
        rotationTask?.cancel(); rotationTask = nil; rotating = false
        recoveryTask?.cancel(); recoveryTask = nil
        stopEngine(); feed.endAudio(); task?.cancel()
        task = nil; request = nil; recognizer = nil; feed.reset(); level = 0
    }
    private func stopEngine() {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        level = 0
    }
}
