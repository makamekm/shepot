#if DEBUG
import AppKit
import SwiftUI

/// Renders our own view offscreen for layout review, without audio, hotkeys or network calls.
@MainActor
enum HUDPreviewRenderer {
    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel()
        model.phase = .recording
        model.elapsed = 24
        model.recorder.level = 0.7
        model.recorder.isOnDevice = true
        let scenarios = [
            ("recording-short", "Привет! Давай встретимся завтра в три часа и обсудим новый проект."),
            ("recording-long", String(repeating: "Я надиктовываю длинную мысль, чтобы проверить прокрутку и видимость текста. ", count: 12) + "Последние слова должны быть хорошо видны."),
            ("recording-hour", (0..<1000).map { "Часть \($0): предыдущие слова сохраняются, а следующие добавляются к длинному разговору. " }.joined() + "Самый конец часовой записи: весь предыдущий текст доступен при прокрутке."),
            ("processing-editing", "Это уже распознанный текст. Пока Luna его редактирует, я могу вставить его без AI одним нажатием Control."),
            ("recording-recovery", "Уже распознанные слова сохраняются, даже если служба Apple временно прервала соединение.")
        ]
        for (name, text) in scenarios {
            model.recorder.transcript = text
            model.elapsed = name == "recording-hour" ? 3785 : 24
            model.phase = name == "processing-editing" ? .processing : .recording
            model.processingStep = .editing
            model.processingElapsed = 4.3
            model.lastText = text
            model.message = "Codex Luna редактирует текст…"
            model.recorder.status = name == "recording-recovery" ? "Восстанавливаю распознавание. Продолжайте говорить…" : ""
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: RecordingHUD.panelSize), styleMask: [.borderless], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: RecordingHUD(app: model, recorder: model.recorder))
            host.sizingOptions = []
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: RecordingHUD.panelSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw AppError.message("Cannot allocate preview bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("Cannot encode preview") }
            try data.write(to: directory.appendingPathComponent("\(name).png"))
        }
    }
}
#endif
