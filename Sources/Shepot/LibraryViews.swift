import SwiftUI
import WhisperCore

struct HistoryRow: View {
    var entry: Dictation
    var onDelete: () -> Void
    @State private var expanded = false
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: entry.style.symbol).foregroundStyle(Palette.accent)
                Text(entry.style.title).font(.system(size: 11, weight: .medium))
                Text("· \(entry.app)").font(.system(size: 11)).foregroundStyle(Palette.muted)
                if entry.usedAI { Text("AI").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.accent).padding(.horizontal, 5).padding(.vertical, 2).background(Palette.lavender, in: Capsule()) }
                Spacer()
                Text(entry.date, format: .dateTime.day().month(.abbreviated).hour().minute()).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Text(entry.text).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled).lineLimit(expanded ? nil : 3).frame(maxWidth: .infinity, alignment: .leading)
            if expanded {
                Divider()
                Text("КАК БЫЛО СКАЗАНО").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(Palette.muted)
                Text(entry.original).font(.system(size: 12)).foregroundStyle(Palette.muted).textSelection(.enabled)
            }
            HStack(spacing: 14) {
                Text("\(entry.words) слов · \(Int(entry.duration)) сек").font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer()
                Button(expanded ? "Свернуть" : "Оригинал") { expanded.toggle() }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                Button { TextInserter.copy(entry.text); copied = true; Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copied = false } } label: { Label(copied ? "Скопировано" : "Копировать", systemImage: copied ? "checkmark" : "doc.on.doc") }.buttonStyle(.plain)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(Palette.muted).help("Удалить диктовку")
            }.font(.system(size: 10))
        }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.line))
    }
}

struct HistoryView: View {
    @ObservedObject var history: HistoryStore
    @State private var query = ""
    @State private var confirmClear = false
    @State private var exportError: String?
    private var filtered: [Dictation] { history.entries.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.original.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        SectionHeading(eyebrow: "Ни одна мысль не потеряется", title: "Ваша история", subtitle: "Последние 200 диктовок. Готовый текст и то, как вы это сказали.")
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
            TextField("Найти мысль…", text: $query).textFieldStyle(.plain).accessibilityLabel("Поиск в истории")
            Spacer()
            Button("Экспорт") { export() }.buttonStyle(QuietButton()).disabled(history.entries.isEmpty)
            Button { confirmClear = true } label: { Image(systemName: "trash") }.buttonStyle(QuietButton()).disabled(history.entries.isEmpty).help("Очистить всю историю")
        }.padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
        if let error = history.storageError ?? exportError { Text(error).foregroundStyle(.red).font(.system(size: 12)) }
        if filtered.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: query.isEmpty ? "clock" : "magnifyingglass").font(.system(size: 34, weight: .light)).foregroundStyle(Palette.accent)
                Text(query.isEmpty ? "Пока тихо" : "Ничего не нашлось").font(.system(size: 20, weight: .medium))
                Text(query.isEmpty ? "Первая диктовка появится здесь. Нажмите ⌃ дважды." : "Попробуйте поискать другими словами.").foregroundStyle(Palette.muted)
            }.frame(maxWidth: .infinity).padding(.vertical, 80)
        } else {
            LazyVStack(spacing: 12) { ForEach(filtered) { entry in HistoryRow(entry: entry, onDelete: { history.remove(entry.id) }) } }
        }
        Text("История хранится только на этом Mac. Сохранение можно отключить в настройках.").font(.system(size: 11)).foregroundStyle(Palette.muted)
            .alert("Удалить всю историю?", isPresented: $confirmClear) {
                Button("Отмена", role: .cancel) {}
                Button("Удалить", role: .destructive) { history.clear() }
            } message: { Text("Сохранённые диктовки будут удалены с этого Mac.") }
    }
    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Шёпот — история.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = history.entries.map { "\($0.date.formatted()) · \($0.style.title)\n\($0.text)\n\nОригинал: \($0.original)" }.joined(separator: "\n\n────────────\n\n")
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { exportError = "Не удалось экспортировать: \(error.localizedDescription)" }
    }
}

struct DictionaryView: View {
    @ObservedObject var settings: AppSettings
    @State private var spoken = ""
    @State private var written = ""
    var body: some View {
        SectionHeading(eyebrow: "Чтобы понимать с полуслова", title: "Мой словарь", subtitle: "Имена, названия и термины — именно так, как пишете вы.")
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) { Image(systemName: "lightbulb").foregroundStyle(Palette.accent); Text("Например: «фигма» → «Figma» или «люиза» → «Луиза».").font(.system(size: 12)) }
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) { Text("Как звучит").font(.system(size: 11)).foregroundStyle(Palette.muted); TextField("фигма", text: $spoken).textFieldStyle(.roundedBorder).accessibilityLabel("Как звучит") }
                Image(systemName: "arrow.right").padding(.bottom, 6).foregroundStyle(Palette.muted)
                VStack(alignment: .leading, spacing: 7) { Text("Как писать").font(.system(size: 11)).foregroundStyle(Palette.muted); TextField("Figma", text: $written).textFieldStyle(.roundedBorder).accessibilityLabel("Как писать") }
                Button("Добавить") { add() }.buttonStyle(PrimaryButton(compact: true)).disabled(spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).background(Palette.lavender.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        if settings.dictionary.isEmpty {
            VStack(spacing: 13) {
                Image(systemName: "character.book.closed").font(.system(size: 34, weight: .light)).foregroundStyle(Palette.accent)
                Text("Слова, которые важны вам").font(.system(size: 19, weight: .medium))
                Text("Добавьте первое слово — Шёпот запомнит написание.").foregroundStyle(Palette.muted)
            }.frame(maxWidth: .infinity).padding(.vertical, 65)
        } else {
            VStack(spacing: 0) {
                ForEach(settings.dictionary) { entry in
                    HStack(spacing: 16) {
                        Text(entry.spoken).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(Palette.muted)
                        Text(entry.written).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
                        Button { settings.dictionary.removeAll { $0.id == entry.id } } label: { Image(systemName: "xmark").foregroundStyle(Palette.muted) }.buttonStyle(.plain).help("Удалить \(entry.spoken)")
                    }.padding(17)
                    if entry.id != settings.dictionary.last?.id { Divider().padding(.horizontal, 17) }
                }
            }.background(.white, in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.line))
        }
    }
    private func add() {
        let key = spoken.trimmingCharacters(in: .whitespacesAndNewlines), value = written.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = settings.dictionary.firstIndex(where: { $0.spoken.caseInsensitiveCompare(key) == .orderedSame }) {
            settings.dictionary[index].written = value
        } else { settings.dictionary.append(DictionaryEntry(spoken: key, written: value)) }
        spoken = ""; written = ""
    }
}
