import SwiftUI
import WhisperCore

struct ContentView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryStore
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 214)
            Rectangle().fill(Palette.line).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    switch app.section {
                    case .home: HomeView(app: app, settings: settings, history: history)
                    case .history: HistoryView(history: history)
                    case .dictionary: DictionaryView(settings: settings)
                    case .settings: SettingsView(app: app, settings: settings)
                    }
                }.padding(.horizontal, 38).padding(.top, 47).padding(.bottom, 32).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
            }.background(Palette.background).id(app.section)
        }
        .foregroundStyle(Palette.ink).font(.system(size: 13))
        .frame(minWidth: 960, minHeight: 720)
        .preferredColorScheme(.light)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in app.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in app.refreshPermissions() }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark()
                Text("шёпот").font(.system(size: 25, weight: .semibold)).tracking(-1)
                Text("beta").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.muted).padding(.horizontal, 5).padding(.vertical, 3).overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.line))
            }.padding(.bottom, 39)
            Text("ВАШЕ ПРОСТРАНСТВО").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(Palette.muted).padding(.leading, 10).padding(.bottom, 12)
            ForEach(AppSection.allCases, id: \.self) { section in
                Button { app.section = section } label: {
                    HStack(spacing: 11) {
                        Image(systemName: section.symbol).font(.system(size: 15)).frame(width: 19)
                        Text(section.rawValue).font(.system(size: 13, weight: app.section == section ? .semibold : .regular))
                        Spacer()
                        if section == .history && !history.entries.isEmpty {
                            Text("\(history.entries.count)").font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }
                    }.foregroundStyle(app.section == section ? Palette.ink : Palette.muted)
                        .padding(.horizontal, 11).padding(.vertical, 12)
                        .background(app.section == section ? .white : .clear, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).padding(.bottom, 4)
            }
            Spacer(minLength: 30)
            VStack(alignment: .leading, spacing: 10) {
                HStack { Image(systemName: "command"); Text("Всегда под рукой").fontWeight(.medium) }.font(.system(size: 12))
                Text("Дважды Control — начать.\nОдин Control — закончить.").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
                HStack(spacing: 5) { KeyCap(); KeyCap(); Spacer(); Text("× 2").font(.system(size: 11)).foregroundStyle(Palette.muted) }.padding(.top, 3)
            }.padding(15).background(Palette.background, in: RoundedRectangle(cornerRadius: 13))
            HStack(spacing: 7) {
                Circle().fill(app.accessibility ? Palette.green : .orange).frame(width: 6, height: 6)
                Text(app.accessibility ? "Готов к диктовке" : "Нужна настройка доступа").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }.padding(.top, 20).padding(.leading, 6)
            Text("Сделано для ваших мыслей").font(.system(size: 9)).foregroundStyle(Palette.muted.opacity(0.7)).padding(.leading, 6).padding(.top, 8)
        }.padding(.horizontal, 18).padding(.top, 55).padding(.bottom, 25).background(Palette.sidebar)
    }
}

struct HomeView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryStore
    @State private var showPlayground = false
    var body: some View {
        HStack(alignment: .top) {
            SectionHeading(eyebrow: "Голос — ваша новая клавиатура", title: "Просто скажите.\nОстальное — шёпотом.", subtitle: "От мысли до готового текста. В любом приложении.")
            Spacer()
            Tag(text: settings.useAI ? settings.editorBackend.title : "Базовый режим", color: settings.useAI ? Palette.accent : Palette.green).padding(.top, 3)
        }
        if app.isBusy { InWindowRecordingView(app: app, recorder: app.recorder) }
        hero
        if !app.accessibility || !app.microphone || !app.speechPermission {
            HStack(spacing: 13) {
                Image(systemName: "hand.raised").font(.system(size: 20)).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Один раз настроить — и можно говорить").font(.system(size: 12, weight: .semibold))
                    Text("Микрофон, распознавание речи и универсальный доступ для ⌃⌃.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("Настроить") { app.section = .settings }.buttonStyle(QuietButton())
            }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.line))
        }
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Ваш текст, ваш стиль").font(.system(size: 16, weight: .semibold)).tracking(-0.3)
                Spacer()
                Text(settings.useAI ? "Применится к следующей диктовке" : "Тон и редактура — с AI в настройках").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            HStack(spacing: 10) {
                ForEach(WritingStyle.allCases) { style in
                    Button { settings.style = style } label: {
                        VStack(alignment: .leading, spacing: 13) {
                            HStack {
                                Image(systemName: style.symbol).font(.system(size: 17))
                                Spacer()
                                if settings.style == style { Image(systemName: "checkmark.circle.fill").font(.system(size: 13)) }
                            }
                            Text(style.title).font(.system(size: 12, weight: .semibold))
                            Text(styleCaption(style)).font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }.foregroundStyle(settings.style == style ? Palette.accent : Palette.ink).padding(15).frame(maxWidth: .infinity, alignment: .leading)
                            .background(settings.style == style ? Palette.lavender.opacity(0.65) : .white, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(settings.style == style ? Palette.accent.opacity(0.55) : Palette.line, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
        }
        HStack(alignment: .center) {
            HStack(spacing: 21) {
                stat("\(history.entries.reduce(0) { $0 + $1.words })", "слов надиктовано")
                Rectangle().fill(Palette.line).frame(width: 1, height: 28)
                stat("\(history.entries.count)", "сохранённых мыслей")
            }
            Spacer()
            Button { showPlayground.toggle() } label: { Label(showPlayground ? "Скрыть редактор" : "Попробовать на тексте", systemImage: "text.cursor") }.buttonStyle(QuietButton())
        }.padding(.top, 3)
        if showPlayground { playground }
        HStack {
            Text("ПОСЛЕДНИЕ ДИКТОВКИ").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(Palette.muted)
            Spacer()
            Button("Вся история ↗") { app.section = .history }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.padding(.top, 1)
        if let entry = history.entries.first { HistoryRow(entry: entry, onDelete: { history.remove(entry.id) }) }
        else {
            HStack(spacing: 12) {
                Image(systemName: "text.bubble").font(.system(size: 22)).foregroundStyle(Palette.muted.opacity(0.6))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Здесь будет ваша первая мысль").font(.system(size: 12, weight: .medium))
                    Text("Нажмите Control дважды и расскажите что-нибудь.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
        }
    }
    private var hero: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 6) { Image(systemName: "waveform"); Text("ВАШИ МЫСЛИ. БЕЗ ЛИШНИХ КЛАВИШ.").tracking(1) }.font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.accent)
                Text("Говорите как думаете.\nПишите как хотите.").font(.system(size: 24, weight: .medium)).tracking(-0.7).lineSpacing(3)
                Text("Шёпот запишет речь, а AI уберёт лишнее,\nрасставит знаки и сохранит ваш смысл.").font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(5)
                HStack(spacing: 13) {
                    Button { app.toggle() } label: { Label(app.phase == .recording ? "Завершить" : app.isBusy ? "Обрабатываем…" : "Начать диктовку", systemImage: app.phase == .recording ? "stop.fill" : "mic.fill") }.buttonStyle(PrimaryButton()).disabled(app.isBusy && app.phase != .recording)
                    HStack(spacing: 4) { KeyCap(); if app.phase != .recording { KeyCap() } }
                        .help(app.phase == .recording ? "Один Control — закончить запись" : "Дважды нажмите и отпустите Control")
                }.padding(.top, 4)
            }
            Spacer(minLength: 4)
            VStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Palette.accent.opacity(0.07), lineWidth: 1).frame(width: 182, height: 182)
                    Circle().stroke(Palette.accent.opacity(0.09), lineWidth: 1).frame(width: 140, height: 140)
                    Circle().fill(.white.opacity(0.7)).frame(width: 100, height: 100)
                    Image(systemName: "mic.fill").font(.system(size: 34, weight: .light)).foregroundStyle(Palette.accent)
                    Image(systemName: "sparkle").font(.system(size: 20)).foregroundStyle(Palette.accent.opacity(0.6)).offset(x: 66, y: -43)
                }.frame(height: 155)
                HStack(spacing: 7) { Circle().fill(Palette.green).frame(width: 5, height: 5); Text("Мысль → готовый текст").font(.system(size: 10, weight: .medium)) }.padding(.horizontal, 13).padding(.vertical, 8).background(.white.opacity(0.75), in: Capsule())
            }.frame(width: 190)
        }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Color(hex: 0xEEEAF6), Color(hex: 0xF2F0F8), Color(hex: 0xE9EEE8)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20))
    }
    private var playground: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Попробуйте редактуру без микрофона").fontWeight(.semibold)
            Text("В базовом режиме — пунктуация и словарь. Для полноценной редактуры включите AI в настройках.").font(.system(size: 11)).foregroundStyle(Palette.muted)
            TextEditor(text: $app.editorInput).font(.system(size: 13)).scrollContentBackground(.hidden).padding(8).frame(height: 90).background(Palette.background, in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Исходный текст")
            HStack {
                Button(app.editorBusy ? "Оформляем…" : "Оформить текст") { app.editSample() }.buttonStyle(PrimaryButton(compact: true)).disabled(app.editorBusy || app.editorInput.isEmpty)
                if !app.editorOutput.isEmpty {
                    Button("Скопировать") { TextInserter.copy(app.editorOutput) }.buttonStyle(QuietButton())
                }
                Spacer()
            }
            if !app.editorOutput.isEmpty { Text(app.editorOutput).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.lavender, in: RoundedRectangle(cornerRadius: 9)) }
            if !app.editorMessage.isEmpty { Text(app.editorMessage).font(.system(size: 11)).foregroundStyle(Palette.muted) }
        }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line))
    }
    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(value).font(.system(size: 22, weight: .medium)).monospacedDigit(); Text(label).font(.system(size: 10)).foregroundStyle(Palette.muted) }
    }
    private func styleCaption(_ style: WritingStyle) -> String {
        switch style { case .clean: return "Ваш голос, без ошибок"; case .casual: return "Легко и естественно"; case .business: return "Ясно и профессионально"; case .list: return "Всё по пунктам" }
    }
}
