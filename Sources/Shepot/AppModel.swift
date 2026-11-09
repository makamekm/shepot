import AppKit
import SwiftUI
import WhisperCore
import OSLog

enum RecordingPhase { case idle, authorizing, recording, processing, success, unverified, error }
enum ProcessingStep { case speech, editing, insertion }

enum AppSection: String, CaseIterable {
    case home = "Главная", history = "История", dictionary = "Мой словарь", settings = "Настройки"
    var symbol: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .history: return "clock.arrow.circlepath"
        case .dictionary: return "character.book.closed"
        case .settings: return "slider.horizontal.3"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let settings = AppSettings()
    let history: HistoryStore
    let recorder = SpeechRecorder()
    let hotkey = HotkeyMonitor()
    private let inserter = TextInserter()
    @Published var section: AppSection = .home
    @Published var phase: RecordingPhase = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var message = ""
    @Published var lastText = ""
    @Published var accessibility = TextInserter.accessibilityGranted
    @Published var microphone = SpeechRecorder.microphoneGranted
    @Published var speechPermission = SpeechRecorder.speechGranted
    @Published var editorInput = ""
    @Published var editorOutput = ""
    @Published var editorBusy = false
    @Published var editorMessage = ""
    @Published var codexStatus = "Проверяем установленный Codex…"
    @Published var codexChecking = false
    @Published var inputTestRunning = false
    @Published var inputTestStatus = ""
    @Published var processingStep: ProcessingStep = .speech
    @Published var processingElapsed: TimeInterval = 0
    @Published var lastTimingSummary = ""
    private var progressTimer: Timer?
    private var stepStartedAt = ProcessInfo.processInfo.systemUptime
    private var timings: [(String, TimeInterval)] = []
    private let logger = Logger(subsystem: "app.shepot.mac", category: "Dictation")
    private struct PreparedDictation {
        var base: String
        var destination: TextInserter.Target?
        var historyID: UUID?
    }
    private var prepared: PreparedDictation?
    private var recordingHistoryID: UUID?
    var showHUD: (() -> Void)?
    var hideHUD: (() -> Void)?
    private var target: TextInserter.Target?
    private var startedAt = Date()
    private var timer: Timer?
    private var permissionTimer: Timer?
    private var work: Task<Void, Never>?
    private var inputTestTask: Task<Void, Never>?
    private var generation = UUID()
    var isBusy: Bool { [.authorizing, .recording, .processing].contains(phase) }
    var timeLabel: String {
        let seconds = Int(elapsed)
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                               : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    init(history: HistoryStore? = nil) {
        self.history = history ?? HistoryStore()
        recorder.onCheckpoint = { [weak self] text in self?.checkpointRecording(text) }
        hotkey.isRecording = { [weak self] in self?.phase == .recording }
        hotkey.onStart = { [weak self] in self?.start() }
        hotkey.onStop = { [weak self] in self?.finish() }
        hotkey.isProcessing = { [weak self] in self?.phase == .processing }
        hotkey.onSkipEditing = { [weak self] in self?.skipEditing() }
        hotkey.onEscape = { [weak self] in
            guard let self else { return }
            // Escape in another app (autocomplete/search) must not cancel an AI edit.
            if self.phase == .processing,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier { return }
            if self.isBusy || self.inputTestRunning { self.cancel() }
        }
    }
    func refreshPermissions() {
        let wasGranted = accessibility
        let currentAccessibility = TextInserter.accessibilityGranted
        let currentMicrophone = SpeechRecorder.microphoneGranted
        let currentSpeech = SpeechRecorder.speechGranted
        if accessibility != currentAccessibility { accessibility = currentAccessibility }
        if microphone != currentMicrophone { microphone = currentMicrophone }
        if speechPermission != currentSpeech { speechPermission = currentSpeech }
        if accessibility && !wasGranted { hotkey.stop(); hotkey.start() }
    }
    func startPermissionMonitoring() {
        guard permissionTimer == nil else { return }
        refreshPermissions()
        let polling = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        permissionTimer = polling
        RunLoop.main.add(polling, forMode: .common)
    }
    func stopPermissionMonitoring() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }
    func toggle() {
        if phase == .recording { finish() }
        else if !isBusy { start() }
    }
    func start() {
        guard !isBusy, !inputTestRunning else { return }
        work?.cancel()
        let id = UUID(); generation = id
        lastText = ""; prepared = nil; recordingHistoryID = nil; timings = []; lastTimingSummary = ""
        target = inserter.captureTarget()
        guard target?.secure != true else {
            message = "Выбрано поле пароля. Переключитесь в обычное текстовое поле."
            phase = .error; showHUD?(); return
        }
        phase = .authorizing; elapsed = 0; message = "Подключаем микрофон…"
        showHUD?()
        work = Task { @MainActor in
            do {
                try await SpeechRecorder.authorize()
                guard generation == id, !Task.isCancelled else { return }
                refreshPermissions()
                try recorder.start(language: settings.language, offlineOnly: settings.offlineOnly, hints: settings.dictionary.map(\.written))
                phase = .recording; startedAt = Date(); message = "Говорите, я записываю"
                timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.phase == .recording else { return }
                        self.elapsed = Date().timeIntervalSince(self.startedAt)
                    }
                }
            } catch {
                guard generation == id else { return }
                recorder.cancel(); phase = .error; message = error.localizedDescription
                refreshPermissions()
            }
        }
    }
    private func checkpointRecording(_ text: String) {
        guard phase == .recording, settings.saveHistory, !text.isEmpty else { return }
        let entry = Dictation(id: recordingHistoryID ?? UUID(), date: startedAt, original: text,
                             text: TextProcessing.clean(text, style: settings.style), style: settings.style,
                             duration: Date().timeIntervalSince(startedAt), app: target?.appName ?? "Шёпот", usedAI: false)
        recordingHistoryID = entry.id; history.upsert(entry)
    }
    func finish() {
        guard phase == .recording else { return }
        timer?.invalidate(); timer = nil
        elapsed = Date().timeIntervalSince(startedAt)
        let duration = elapsed
        let id = generation
        let style = settings.style
        let dictionary = settings.dictionary
        let useAI = settings.useAI
        let model = settings.model
        let backend = settings.editorBackend
        let codexPath = settings.codexPath
        let destination = target
        phase = .processing
        beginStep(.speech, message: "Завершаю распознавание…")
        lastText = TextProcessing.clean(recorder.transcript, style: style)
        work = Task { @MainActor in
            let raw = await recorder.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            guard generation == id, !Task.isCancelled else { return }
            let speechFailure = recorder.failureMessage
            recorder.cancel()
            guard !raw.isEmpty else {
                stopProgress(); phase = .error; message = speechFailure
                return
            }
            let base = TextProcessing.clean(TextProcessing.applyDictionary(raw, entries: dictionary), style: style)
            lastText = base
            var historyID: UUID?
            if settings.saveHistory {
                let entry = Dictation(id: recordingHistoryID ?? UUID(), date: startedAt, original: raw, text: base, style: style, duration: duration, app: destination?.appName ?? "Шёпот", usedAI: false)
                historyID = entry.id; recordingHistoryID = entry.id; history.upsert(entry)
            }
            let pending = PreparedDictation(base: base, destination: destination, historyID: historyID)
            prepared = pending
            if useAI { beginStep(.editing, message: backend == .codexLuna ? "Codex Luna редактирует текст…" : "AI редактирует текст…") }
            do {
                let edited = try await DictationEditing.run(base: base, useAI: useAI, style: style, timeout: backend.timeout) {
                    switch backend {
                    case .codexLuna:
                        return try await CodexEditor().edit(raw, style: style, dictionary: dictionary, executablePath: codexPath)
                    case .openAI:
                        guard let key = Keychain.read(), !key.isEmpty else { throw AppError.message("Добавьте API-ключ в настройках.") }
                        return try await AIEditor().edit(raw, style: style, dictionary: dictionary, model: model, key: key)
                    }
                }
                guard generation == id, !Task.isCancelled else { return }
                await deliverPrepared(edited, pending: pending, generation: id)
            } catch {
                guard generation == id, !Task.isCancelled else { return }
                stopProgress(); phase = .error
                message = "Обработка прервалась. Распознанный текст сохранён: " + error.localizedDescription
            }
        }
    }
    private func deliverPrepared(_ edited: EditedDictation, pending: PreparedDictation, generation id: UUID) async {
        guard generation == id, !Task.isCancelled else { return }
        lastText = edited.text
        if !edited.notice.isEmpty { logger.error("AI fallback: \(edited.notice, privacy: .public)") }
        if let historyID = pending.historyID { history.update(historyID, text: edited.text, usedAI: edited.usedAI) }
        beginStep(.insertion, message: "Ввожу текст…")
        let delivery = await inserter.deliver(edited.text, to: pending.destination)
        guard generation == id, !Task.isCancelled else { return }
        completeInsertion(delivery)
        if !edited.notice.isEmpty { message += " · " + edited.notice }
        prepared = nil
    }
    func skipEditing() {
        guard phase == .processing, processingStep == .editing, let pending = prepared else { return }
        let id = UUID(); generation = id
        work?.cancel()
        logger.info("AI skipped by Control; draft retained")
        work = Task { @MainActor in
            await deliverPrepared(EditedDictation(text: pending.base, usedAI: false, notice: "Введено без AI по вашему запросу."), pending: pending, generation: id)
        }
    }
    private func beginStep(_ step: ProcessingStep, message: String) {
        if progressTimer != nil { recordStepDuration() }
        processingStep = step; self.message = message
        stepStartedAt = ProcessInfo.processInfo.systemUptime; processingElapsed = 0
        guard progressTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.processingElapsed = ProcessInfo.processInfo.systemUptime - self.stepStartedAt
            }
        }
        progressTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func recordStepDuration() {
        let title: String
        switch processingStep { case .speech: title = "Речь"; case .editing: title = "AI"; case .insertion: title = "Ввод" }
        let seconds = ProcessInfo.processInfo.systemUptime - stepStartedAt
        timings.append((title, seconds))
        logger.info("Stage \(title, privacy: .public): \(seconds) seconds")
    }
    private func stopProgress() {
        if progressTimer != nil { recordStepDuration() }
        progressTimer?.invalidate(); progressTimer = nil
        lastTimingSummary = timings.map { "\($0.0): \(String(format: "%.1f", $0.1)) с" }.joined(separator: " · ")
    }
    func retryInsertion() {
        guard !isBusy, !lastText.isEmpty else { return }
        let destination = inserter.captureTarget()
        let id = generation
        phase = .processing; message = "Вставляю текст…"
        work = Task { @MainActor in
            let delivery = await inserter.deliver(lastText, to: destination)
            guard generation == id else { return }
            completeInsertion(delivery)
        }
    }
    func completeInsertion(_ delivery: InsertionResult) {
        stopProgress()
        message = delivery.message
        switch delivery.outcome {
        case .confirmed: phase = .success
        case .sentUnverified: phase = .unverified
        case .failed: phase = .error
        }
        if delivery.shouldDismissHUD { hideHUD?() }
    }
    func checkCodex() {
        guard !codexChecking else { return }
        codexChecking = true
        let path = CodexEditor.nativeExecutable(for: settings.codexPath)
        Task { @MainActor in
            defer { codexChecking = false }
            guard FileManager.default.isExecutableFile(atPath: path) else {
                codexStatus = "Codex CLI не найден. Укажите путь к установленному codex."
                return
            }
            do {
                let status = try await CommandRunner().run(executable: URL(fileURLWithPath: path), arguments: ["login", "status"], timeout: 8)
                let output = String(decoding: status.output + status.error, as: UTF8.self)
                if status.status == 0 {
                    codexStatus = output.contains("ChatGPT") ? "Установлен · вход через ChatGPT · Luna" : "Установлен · вход выполнен · Luna"
                } else if output.lowercased().contains("not logged in") || output.lowercased().contains("login") {
                    codexStatus = "Codex установлен. Выполните codex login в Терминале."
                } else {
                    let detail = CodexEditor.diagnostic(status)
                    codexStatus = "Codex не запускается (\(status.status))" + (detail.isEmpty ? "." : ": \(detail)")
                }
            } catch { codexStatus = error.localizedDescription }
        }
    }
    func testInput() {
        guard !isBusy, !inputTestRunning else { return }
        inputTestRunning = true
        inputTestTask = Task { @MainActor in
            defer { inputTestRunning = false }
            for seconds in stride(from: 5, through: 1, by: -1) {
                inputTestStatus = "Выберите поле ввода. Проверка через \(seconds) сек… Esc — отменить."
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { inputTestStatus = "Проверка отменена."; return }
            }
            let destination = inserter.captureTarget()
            let testText = "Шёпот: проверка ввода 👋"
            let result = await inserter.deliver(testText, to: destination)
            guard !Task.isCancelled else { return }
            inputTestStatus = result.message
            lastText = testText
            completeInsertion(result)
            if !result.shouldDismissHUD { showHUD?() }
        }
    }
    func cancel() {
        if isBusy {
            let capturingSpeech = phase == .recording || (phase == .processing && processingStep == .speech)
            if capturingSpeech, !recorder.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lastText = TextProcessing.clean(TextProcessing.applyDictionary(recorder.transcript, entries: settings.dictionary), style: settings.style)
            }
            if !lastText.isEmpty, capturingSpeech, prepared == nil, settings.saveHistory {
                let entry = Dictation(id: recordingHistoryID ?? UUID(), date: startedAt, original: recorder.transcript, text: lastText, style: settings.style, duration: elapsed, app: target?.appName ?? "Шёпот", usedAI: false)
                recordingHistoryID = entry.id; history.upsert(entry)
            }
            logger.info("Cancelled explicitly; hasDraft=\(!self.lastText.isEmpty)")
        }
        stopProgress(); prepared = nil
        generation = UUID()
        inputTestTask?.cancel(); inputTestTask = nil
        work?.cancel(); work = nil
        timer?.invalidate(); timer = nil
        recorder.cancel()
        phase = .idle
        message = lastText.isEmpty ? "Отменено." : "Отменено. Распознанный текст сохранён."
        hideHUD?()
    }
    func requestPermissions() {
        Task { @MainActor in
            do { try await SpeechRecorder.authorize() }
            catch { message = error.localizedDescription }
            refreshPermissions()
        }
    }
    func editSample() {
        guard !editorBusy, !editorInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        editorBusy = true; editorMessage = ""
        let raw = editorInput, style = settings.style, entries = settings.dictionary, ai = settings.useAI, model = settings.model
        let backend = settings.editorBackend, codexPath = settings.codexPath
        Task { @MainActor in
            defer { editorBusy = false }
            let base = TextProcessing.clean(TextProcessing.applyDictionary(raw, entries: entries), style: style)
            do {
                let edited = try await DictationEditing.run(base: base, useAI: ai, style: style, timeout: backend.timeout) {
                    switch backend {
                    case .codexLuna:
                        return try await CodexEditor().edit(raw, style: style, dictionary: entries, executablePath: codexPath)
                    case .openAI:
                        guard let key = Keychain.read(), !key.isEmpty else { throw AppError.message("Добавьте API-ключ в настройках.") }
                        return try await AIEditor().edit(raw, style: style, dictionary: entries, model: model, key: key)
                    }
                }
                editorOutput = edited.text
                editorMessage = edited.usedAI ? "Готово · \(backend.title)" : (edited.notice.isEmpty ? "Готово · базовая обработка" : edited.notice)
            } catch { editorOutput = base; editorMessage = error.localizedDescription + " Показана базовая обработка." }
        }
    }
}
