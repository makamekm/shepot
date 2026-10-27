import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: AppSettings
    @State private var key = ""
    @State private var keyMessage = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError = ""
    var body: some View {
        SectionHeading(eyebrow: "Всё под вашим контролем", title: "Пусть будет удобно", subtitle: "Несколько настроек — и Шёпот работает так, как нужно вам.")
        card("01", "Доступ к macOS", "Нужен для записи и вставки текста в другие приложения.") {
            permissionRow("Микрофон и распознавание речи", detail: "Аудио не сохраняется в файлы.", granted: app.microphone && app.speechPermission, action: {
                if app.microphone && app.speechPermission { return }
                app.requestPermissions()
            })
            Divider()
            permissionRow("Универсальный доступ", detail: "Двойной Control и прямой ввод текста в поле.", granted: app.accessibility, action: { TextInserter.requestAccessibility() })
            HStack {
                Text("Статус обновляется автоматически после выдачи доступа.").font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer()
                Button("Проверить доступ") { app.refreshPermissions() }.buttonStyle(QuietButton())
            }
            HStack {
                Text("Разрешение нужно для этой копии Шёпота.").font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer()
                Button("Показать приложение") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }.buttonStyle(QuietButton())
            }
            if !app.message.isEmpty && app.phase != .recording { Text(app.message).font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled) }
            if !app.lastTimingSummary.isEmpty {
                Text(app.lastTimingSummary).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
            }
            HStack(spacing: 15) {
                Button("Настройки микрофона ↗") { openPrivacy("Microphone") }.buttonStyle(.plain)
                Button("Распознавание речи ↗") { openPrivacy("SpeechRecognition") }.buttonStyle(.plain)
            }.font(.system(size: 10)).foregroundStyle(Palette.accent)
        }
        card("02", "Диктовка", "Дважды Control — начать. Один Control во время записи — закончить.") {
            HStack {
                Label("Язык речи", systemImage: "globe")
                Spacer()
                Picker("Язык речи", selection: $settings.language) {
                    Text("Русский").tag("ru-RU")
                    Text("English (US)").tag("en-US")
                    Text("English (UK)").tag("en-GB")
                    Text("Deutsch").tag("de-DE")
                    Text("Español").tag("es-ES")
                    Text("Français").tag("fr-FR")
                }.labelsHidden().frame(width: 175)
            }
            Divider()
            Label("Текст вводится прямо в выбранное поле", systemImage: "text.cursor").font(.system(size: 12, weight: .medium))
            Text("Буфер обмена не используется. Если вставка недоступна, текст останется в панели с кнопкой «Вставить в поле».").font(.system(size: 10)).foregroundStyle(Palette.muted)
            HStack {
                Button(app.inputTestRunning ? "Проверяем…" : "Проверить ввод") { app.testInput() }
                    .buttonStyle(QuietButton()).disabled(app.inputTestRunning || app.isBusy)
                Text("Через 5 секунд введёт короткий пример в выбранное поле.").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            if !app.inputTestStatus.isEmpty { Text(app.inputTestStatus).font(.system(size: 11)).foregroundStyle(Palette.accent).textSelection(.enabled) }
            Divider()
            Toggle("Распознавание только на устройстве", isOn: $settings.offlineOnly).toggleStyle(.switch).controlSize(.small)
            Text("По умолчанию используется локальная модель, если она доступна. При недоступности или сбое локального распознавателя используется повторная попытка, в том числе через интернет Apple. Строгий локальный режим запрещает этот переход.").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
            Text("Говорите до нажатия Control — общего лимита по времени нет. Новые фразы добавляются к предыдущим; распознавание автоматически продолжается частями. Esc — отменить.").font(.system(size: 10)).foregroundStyle(Palette.muted)
        }
        card("03", "Перефразирование", "Превращает устную речь в ясный, связный текст и сохраняет ваш смысл.") {
            Toggle("Перефразировать и исправлять текст", isOn: $settings.useAI).toggleStyle(.switch).controlSize(.small)
            Picker("Обработчик", selection: $settings.editorBackend) {
                ForEach(EditorBackend.allCases) { backend in Text(backend.title).tag(backend) }
            }.pickerStyle(.segmented)
            if settings.editorBackend == .codexLuna {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Codex · GPT-6 Luna").font(.system(size: 13, weight: .semibold))
                        Text(app.codexStatus).font(.system(size: 11)).foregroundStyle(Palette.accent)
                    }
                    Spacer()
                    Button(app.codexChecking ? "Проверяем…" : "Проверить Codex") { app.checkCodex() }.buttonStyle(QuietButton()).disabled(app.codexChecking)
                }
                TextField("Путь к установленному codex", text: $settings.codexPath).textFieldStyle(.roundedBorder).accessibilityLabel("Путь к Codex CLI")
                Text("Используется установленный Codex CLI и ваш вход в Codex. Отдельный API-ключ не нужен; действуют лимиты Codex. Для перефразирования нужен интернет.").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
            } else {
            HStack(spacing: 9) {
                SecureField(settings.hasAPIKey ? "Новый API-ключ (текущий сохранён)" : "API-ключ OpenAI", text: $key).textFieldStyle(.roundedBorder).accessibilityLabel("API-ключ OpenAI")
                Button("Сохранить") {
                    do { try settings.saveAPIKey(key); key = ""; keyMessage = "Ключ сохранён в Связке ключей." }
                    catch { keyMessage = error.localizedDescription }
                }.buttonStyle(QuietButton()).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if settings.hasAPIKey {
                    Button { do { try settings.saveAPIKey(""); settings.useAI = false; keyMessage = "Ключ удалён." } catch { keyMessage = error.localizedDescription } } label: { Image(systemName: "trash") }.buttonStyle(QuietButton()).help("Удалить ключ")
                }
            }
            if !keyMessage.isEmpty { Text(keyMessage).font(.system(size: 11)).foregroundStyle(Palette.accent) }
            HStack {
                Text("Модель").foregroundStyle(Palette.muted)
                TextField(AIEditor.defaultModel, text: $settings.model).textFieldStyle(.roundedBorder).frame(width: 210)
                Spacer()
                Link("Получить ключ ↗", destination: URL(string: "https://platform.openai.com/api-keys")!).font(.system(size: 11))
            }
            Text("API оплачивается отдельно. Ключ хранится в Связке ключей macOS.").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
            }
            Text("На редактуру отправляется распознанный текст и словарь. Ожидание AI — до 12 секунд. Если AI недоступен, вводится текст с базовой пунктуацией. Во время редактуры Control вставляет без ожидания AI. Буфер обмена не используется.").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
            Text("Без AI: базовая пунктуация, команды «новый абзац», «новая строка» и ваш словарь. Переформулирование и исправление грамматики доступны с AI.").font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(3)
        }.onAppear { app.checkCodex() }
        card("04", "Повседневные мелочи", "Шёпот остаётся в строке меню, когда вы закрываете окно.") {
            Toggle("Сохранять историю на этом Mac", isOn: $settings.saveHistory).toggleStyle(.switch).controlSize(.small)
            Divider()
            Toggle("Открывать при входе в систему", isOn: $launchAtLogin).toggleStyle(.switch).controlSize(.small)
                .onChange(of: launchAtLogin) { _, value in
                    do {
                        if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        launchError = SMAppService.mainApp.status == .requiresApproval ? "Подтвердите автозапуск в Системных настройках → Основные → Объекты входа." : ""
                    } catch { launchError = error.localizedDescription; launchAtLogin = SMAppService.mainApp.status == .enabled }
                }
            if !launchError.isEmpty { Text(launchError).font(.system(size: 11)).foregroundStyle(Palette.muted) }
        }
        HStack { BrandMark(size: 26); Text("Шёпот 0.2.7").font(.system(size: 11, weight: .medium)); Spacer(); Text("Меньше клавиш. Больше вас.").font(.system(size: 11)).foregroundStyle(Palette.muted) }
    }
    private func card<Content: View>(_ number: String, _ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 12) {
                Text(number).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Palette.accent).padding(8).background(Palette.lavender, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 16, weight: .semibold)); Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3) }
            }
            Divider()
            content()
        }.padding(21).background(.white, in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(Palette.line))
    }
    private func permissionRow(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(granted ? Palette.green : Palette.muted).font(.system(size: 18))
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 12, weight: .medium)); Text(detail).font(.system(size: 10)).foregroundStyle(Palette.muted) }
            Spacer()
            if granted { Tag(text: "Разрешено") }
            else { Button("Разрешить", action: action).buttonStyle(QuietButton()) }
        }
    }
    private func openPrivacy(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(anchor)")!)
    }
}
