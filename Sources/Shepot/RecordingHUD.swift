import SwiftUI

enum TranscriptDisplay {
    static func blocks(_ text: String, limit: Int = 2400) -> [String] {
        guard !text.isEmpty else { return [] }
        var result: [String] = [], start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: max(1, limit), limitedBy: text.endIndex) ?? text.endIndex
            var split = end
            if end < text.endIndex, let space = text[start..<end].lastIndex(where: \.isWhitespace), space > start { split = space }
            result.append(String(text[start..<split])); start = split
        }
        return result
    }
}

struct LiveTranscript: View {
    var text: String
    var placeholder = "Говорите свободно. Текст появится здесь…"
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    let blocks = text.isEmpty ? [placeholder] : TranscriptDisplay.blocks(text)
                    ForEach(blocks.indices, id: \.self) { index in
                        Text(blocks[index])
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(text.isEmpty ? Palette.muted : Palette.ink)
                            .lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Расшифровка речи")
                            .accessibilityValue(blocks[index])
                    }
                    Color.clear.frame(height: 1).id("latest-words")
                }.padding(14)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: text) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("latest-words", anchor: .bottom) }
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
        }
    }
}

struct RecordingHUD: View {
    static let panelSize = NSSize(width: 560, height: 334)
    @ObservedObject var app: AppModel
    @ObservedObject var recorder: SpeechRecorder
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                BrandMark(size: 28)
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                if app.phase == .recording {
                    Circle().fill(Color.red.opacity(0.8)).frame(width: 6, height: 6)
                    Text(app.timeLabel).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.ink)
                }
                Button { app.cancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(Palette.muted).frame(width: 26, height: 26)
                }.buttonStyle(.plain).help("Закрыть / Esc")
            }
            if app.phase == .recording {
                Waveform(level: recorder.level, active: true, height: 32)
                if !recorder.status.isEmpty {
                    Text(recorder.status).font(.system(size: 11)).foregroundStyle(Palette.accent)
                }
                LiveTranscript(text: recorder.transcript).frame(maxHeight: .infinity)
                HStack(spacing: 12) {
                    Tag(text: recorder.isOnDevice ? "На устройстве" : "Apple Speech", color: Palette.green)
                    Spacer()
                    Text("Esc — отмена").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Button { app.finish() } label: {
                        Label("Готово · Control", systemImage: "stop.fill")
                    }.buttonStyle(PrimaryButton(compact: true)).help("Остановить запись одним нажатием Control")
                }
            } else if app.phase == .processing || app.phase == .authorizing {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(app.message).font(.system(size: 14)).foregroundStyle(Palette.ink)
                    Spacer()
                    if app.phase == .processing {
                        Text(String(format: "%.1f с", app.processingElapsed)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted)
                    }
                }.padding(.top, 10)
                if app.phase == .processing {
                    LiveTranscript(text: app.lastText.isEmpty ? recorder.transcript : app.lastText, placeholder: "Завершаю распознавание…").frame(maxHeight: .infinity)
                } else { Spacer() }
                if app.phase == .processing, app.processingStep == .editing {
                    HStack {
                        Text("Ожидание AI — до 12 с").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Spacer()
                        Button { app.skipEditing() } label: { Text("Вставить без AI · Control") }.buttonStyle(PrimaryButton(compact: true))
                    }
                } else {
                    Text("× — отменить. Распознанный текст сохранится.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: app.phase == .success ? "checkmark.circle.fill" : "info.circle")
                        .foregroundStyle(app.phase == .success ? Palette.green : Palette.accent)
                    Text(app.message).font(.system(size: 14)).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !app.lastText.isEmpty {
                    LiveTranscript(text: app.lastText).frame(maxHeight: .infinity)
                    if app.phase == .error {
                        HStack {
                            Button { app.retryInsertion() } label: { Label("Вставить в поле", systemImage: "text.cursor") }.buttonStyle(PrimaryButton(compact: true))
                            if !app.accessibility {
                                Button("Разрешить доступ") { TextInserter.requestAccessibility() }.buttonStyle(QuietButton())
                            }
                        }
                    }
                } else { Spacer() }
            }
        }
        .padding(20).frame(width: Self.panelSize.width - 24, height: Self.panelSize.height - 24)
        .background(Palette.background, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.accent.opacity(0.3)))
        .padding(12).foregroundStyle(Palette.ink).preferredColorScheme(.light)
    }
    private var title: String {
        switch app.phase {
        case .recording: return "Слушаю вас"
        case .processing: return "Оформляю текст"
        case .success: return "Готово, мысль записана"
        case .unverified: return "Ввод завершён"
        case .error: return "Небольшая пауза"
        default: return "Шёпот"
        }
    }
}

struct InWindowRecordingView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var recorder: SpeechRecorder
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: app.phase == .recording ? "mic.fill" : "waveform").foregroundStyle(Palette.accent)
                Text(app.phase == .recording ? "Говорите, я слушаю" : app.message).font(.system(size: 14, weight: .semibold))
                Spacer()
                if app.phase == .recording {
                    Text(app.timeLabel).monospacedDigit().foregroundStyle(Palette.muted)
                    Button("Готово · Control") { app.finish() }.buttonStyle(PrimaryButton(compact: true))
                }
                Button("Отменить") { app.cancel() }.buttonStyle(QuietButton())
            }
            LiveTranscript(text: app.phase == .recording || app.lastText.isEmpty ? recorder.transcript : app.lastText).frame(height: 150)
            Text("Один Control — закончить запись. Esc — отменить.").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.padding(18).background(Palette.lavender.opacity(0.65), in: RoundedRectangle(cornerRadius: 15))
    }
}
