import AppKit
import ApplicationServices
import Carbon

@MainActor
protocol TextInputTarget {
    var appName: String { get }
    var secure: Bool { get }
    var prefersKeyboardInput: Bool { get }
    func readState() -> TextInputState?
    func focusProblem() -> String?
    func replaceSelection(_ text: String) -> Bool
    func typeUnicode(_ text: String) async throws
}

extension TextInputTarget { var prefersKeyboardInput: Bool { false } }

struct TextInputState: Equatable {
    var value: String
    var selection: NSRange?

    func expectedValue(inserting text: String) -> String? {
        guard let selection, selection.location != NSNotFound,
              selection.location >= 0, selection.length >= 0,
              selection.location <= value.utf16.count, selection.length <= value.utf16.count - selection.location else { return nil }
        return (value as NSString).replacingCharacters(in: selection, with: text)
    }
    func confirmsInsertion(_ text: String, from before: TextInputState) -> Bool {
        if let expected = before.expectedValue(inserting: text) {
            guard Self.comparable(value) == Self.comparable(expected) else { return false }
            // Replacing a selection with the same text is valid only when the caret advances.
            return value != before.value || selection != before.selection
        }
        let after = Self.comparable(value), previous = Self.comparable(before.value), inserted = Self.comparable(text)
        guard after != previous, !inserted.isEmpty, let range = after.range(of: inserted) else { return false }
        var withoutInsertion = after
        withoutInsertion.removeSubrange(range)
        return Self.comparable(withoutInsertion) == previous
    }
    private static func comparable(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum InputVerification { case confirmed, unchanged, changedUnexpectedly, unavailable }

enum InsertionOutcome { case confirmed, sentUnverified, failed }

enum InputFieldGeometry {
    static func isSameField(_ initial: CGRect, _ current: CGRect) -> Bool {
        let sameColumn = abs(initial.minX - current.minX) < 2 && abs(initial.width - current.width) < 2
        // Chat composers grow upward or downward while receiving a long dictation.
        let sameAnchor = abs(initial.minY - current.minY) < 2 || abs(initial.maxY - current.maxY) < 2
        return sameColumn && sameAnchor
    }
}

struct InsertionResult {
    var outcome: InsertionOutcome
    var message: String
    var inserted: Bool { outcome == .confirmed }
    var shouldDismissHUD: Bool { outcome != .failed }
}

enum UnicodeInput {
    // Respect UTF-16 boundaries, including surrogate pairs, across keyboard events.
    static func chunks(_ text: String, limit: Int = 20) -> [[UniChar]] {
        var chunks: [[UniChar]] = [], current: [UniChar] = []
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if current.count + units.count > max(2, limit) { chunks.append(current); current = [] }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
    static func events(for units: [UniChar]) throws -> (CGEvent, CGEvent) {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw AppError.message("macOS не удалось создать события ввода.")
        }
        down.flags = []; up.flags = []
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        return (down, up)
    }
}

@MainActor
final class TextInserter {
    typealias Target = any TextInputTarget
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        openAccessibilitySettings()
    }
    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func captureTarget() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let responder = NSApp.keyWindow?.firstResponder,
           responder is NSTextInputClient {
            return LocalTextTarget(responder: responder)
        }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let element = Self.focusedElement(pid: app.processIdentifier)
        return ExternalTextTarget(app: app, element: element)
    }
    fileprivate static func focusedElement(pid: pid_t) -> AXUIElement? {
        guard Self.accessibilityGranted else { return nil }
        var value: CFTypeRef?
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// No clipboard access in this path, including all failures and cancellations.
    func deliver(_ text: String, to target: Target?, modifiersDown: () -> Bool = {
        !CGEventSource.flagsState(.combinedSessionState).intersection([.maskControl, .maskCommand, .maskShift, .maskAlternate]).isEmpty
    }) async -> InsertionResult {
        guard !text.isEmpty else { return InsertionResult(outcome: .failed, message: "Нет текста для вставки.") }
        guard let target else { return InsertionResult(outcome: .failed, message: "Выберите поле ввода и нажмите «Вставить в поле».") }
        guard !target.secure else { return InsertionResult(outcome: .failed, message: "В поле пароля текст не вводится. Выберите обычное поле.") }
        // Stopping happens on Control down. Wait for key-up before injecting text.
        for _ in 0..<100 {
            if !modifiersDown() { break }
            do { try await Task.sleep(nanoseconds: 30_000_000) }
            catch { return InsertionResult(outcome: .failed, message: "Вставка отменена.") }
        }
        guard !Task.isCancelled else { return InsertionResult(outcome: .failed, message: "Вставка отменена.") }
        guard !modifiersDown() else { return InsertionResult(outcome: .failed, message: "Отпустите Control и нажмите «Вставить в поле».") }
        if let problem = target.focusProblem() { return InsertionResult(outcome: .failed, message: problem) }
        let before = target.readState()
        if !target.prefersKeyboardInput, before != nil, target.replaceSelection(text) {
            switch await verify(text, before: before, target: target) {
            case .confirmed: return InsertionResult(outcome: .confirmed, message: "Вставлено в \(target.appName)")
            case .unchanged: break // Some AX setters return success while doing nothing.
            case .changedUnexpectedly, .unavailable:
                return InsertionResult(outcome: .failed, message: "Поле изменилось, но вставку подтвердить не удалось. Проверьте текст в поле перед повторной вставкой.")
            }
        }
        do {
            try await target.typeUnicode(text)
            switch await verify(text, before: before, target: target) {
            case .confirmed: return InsertionResult(outcome: .confirmed, message: "Вставлено в \(target.appName)")
            case .unchanged: return InsertionResult(outcome: .failed, message: "Поле не приняло текст. Текст остался в панели, буфер обмена не изменён.")
            case .changedUnexpectedly:
                guard !Task.isCancelled else { return InsertionResult(outcome: .failed, message: "Вставка отменена.") }
                if let problem = target.focusProblem() { return InsertionResult(outcome: .failed, message: problem) }
                return InsertionResult(outcome: .sentUnverified, message: "Ввод завершён; поле изменилось. Точное совпадение автоматически подтвердить не удалось.")
            case .unavailable:
                guard !Task.isCancelled else { return InsertionResult(outcome: .failed, message: "Вставка отменена.") }
                if let problem = target.focusProblem() { return InsertionResult(outcome: .failed, message: problem) }
                // An opaque input is not a confirmed insertion or a known failure.
                // All events were sent; keep the diagnostic without holding the HUD open.
                return InsertionResult(outcome: .sentUnverified, message: "События ввода отправлены, но это поле не позволяет подтвердить результат. Проверьте текст в поле.")
            }
        } catch { return InsertionResult(outcome: .failed, message: error.localizedDescription) }
    }
    private func verify(_ text: String, before: TextInputState?, target: Target) async -> InputVerification {
        guard let before else { return .unavailable }
        var observed: TextInputState?
        for _ in 0..<16 {
            guard !Task.isCancelled, target.focusProblem() == nil else { return .unavailable }
            observed = target.readState()
            if let observed, observed.confirmsInsertion(text, from: before) {
                // Allow the target UI to render; don't trust a transient AX cache update.
                do { try await Task.sleep(nanoseconds: 80_000_000) } catch { return .unavailable }
                if target.readState()?.confirmsInsertion(text, from: before) == true { return .confirmed }
            }
            do { try await Task.sleep(nanoseconds: 30_000_000) } catch { return .unavailable }
        }
        guard let observed else { return .unavailable }
        return observed == before ? .unchanged : .changedUnexpectedly
    }
    static func copy(_ text: String) {
        // Used only by explicit user-facing Copy buttons.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
final class LocalTextTarget: TextInputTarget {
    let appName = "Шёпот"
    let responder: NSResponder
    init(responder: NSResponder) { self.responder = responder }
    var secure: Bool {
        if let view = responder as? NSTextView { return view.delegate is NSSecureTextField }
        return responder is NSSecureTextField
    }
    func focusProblem() -> String? {
        NSApp.keyWindow?.firstResponder === responder ? nil : "Выберите исходное поле и нажмите «Вставить в поле»."
    }
    func replaceSelection(_ text: String) -> Bool {
        guard let client = responder as? NSTextInputClient else { return false }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }
    func readState() -> TextInputState? {
        guard let view = responder as? NSTextView else { return nil }
        return TextInputState(value: view.string, selection: view.selectedRange())
    }
    func typeUnicode(_ text: String) async throws { throw AppError.message("Это поле не поддерживает ввод текста.") }
}

@MainActor
private final class ExternalTextTarget: TextInputTarget {
    let prefersKeyboardInput = true
    let app: NSRunningApplication
    let element: AXUIElement?
    let secure: Bool
    let initialID: String?
    let initialFrame: CGRect?
    let initialRole: String?
    let initialWindow: AXUIElement?
    var appName: String { app.localizedName ?? "приложение" }

    init(app: NSRunningApplication, element: AXUIElement?) {
        self.app = app; self.element = element
        secure = Self.string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
        initialID = Self.string(element, kAXIdentifierAttribute)
        initialRole = Self.string(element, kAXRoleAttribute)
        initialFrame = Self.frame(element)
        initialWindow = Self.window(element)
    }
    func focusProblem() -> String? {
        guard TextInserter.accessibilityGranted else {
            return "Разрешите Шёпоту «Универсальный доступ» в настройках macOS, затем повторите вставку. Буфер обмена не изменён."
        }
        guard !app.isTerminated else { return "Исходное приложение закрыто. Выберите новое поле и нажмите «Вставить в поле»." }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return "Выберите поле в \(appName) и нажмите «Вставить в поле»."
        }
        guard !IsSecureEventInputEnabled() else { return "Защищённый ввод включён. Переключитесь в обычное текстовое поле." }
        let current = TextInserter.focusedElement(pid: app.processIdentifier)
        if Self.string(current, kAXSubroleAttribute) == kAXSecureTextFieldSubrole { return "В поле пароля текст не вводится." }
        guard let element, let current else { return nil }
        if CFEqual(element, current) { return nil }
        let sameWindow: Bool
        if let initialWindow, let currentWindow = Self.window(current) { sameWindow = CFEqual(initialWindow, currentWindow) }
        else { sameWindow = false }
        // Browsers can recreate AX objects for the same input while a dictation is processing.
        if sameWindow, let initialID, !initialID.isEmpty, initialID == Self.string(current, kAXIdentifierAttribute),
           initialRole == Self.string(current, kAXRoleAttribute) { return nil }
        if sameWindow, let initialFrame, let currentFrame = Self.frame(current), initialRole == Self.string(current, kAXRoleAttribute),
           InputFieldGeometry.isSameField(initialFrame, currentFrame) { return nil }
        return "Поле ввода изменилось. Нажмите «Вставить в поле», чтобы ввести текст в выбранное поле."
    }
    func replaceSelection(_ text: String) -> Bool {
        guard let current = TextInserter.focusedElement(pid: app.processIdentifier) else { return false }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(current, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(current, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }
    func readState() -> TextInputState? {
        guard let current = TextInserter.focusedElement(pid: app.processIdentifier),
              let value = Self.string(current, kAXValueAttribute) else { return nil }
        var rangeValue: CFTypeRef?, range: CFRange = CFRange(location: 0, length: 0)
        var selection: NSRange?
        if AXUIElementCopyAttributeValue(current, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID(),
           AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 {
            selection = NSRange(location: range.location, length: range.length)
        }
        return TextInputState(value: value, selection: selection)
    }
    func typeUnicode(_ text: String) async throws {
        guard CGPreflightPostEventAccess() else {
            throw AppError.message("macOS не разрешает отправку клавиш. Проверьте «Универсальный доступ» для Шёпота.")
        }
        for units in UnicodeInput.chunks(text) {
            try Task.checkCancellation()
            if let problem = focusProblem() { throw AppError.message(problem + " Ввод остановлен.") }
            let flags = CGEventSource.flagsState(.combinedSessionState)
            guard flags.intersection([.maskControl, .maskCommand, .maskShift, .maskAlternate]).isEmpty else {
                throw AppError.message("Ввод остановлен: нажата клавиша-модификатор. Текст остался в панели.")
            }
            let (down, up) = try UnicodeInput.events(for: units)
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 12_000_000)
        }
    }
    private static func window(_ element: AXUIElement?) -> AXUIElement? {
        guard let element else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func string(_ element: AXUIElement?, _ attribute: String) -> String? {
        guard let element else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    private static func frame(_ element: AXUIElement?) -> CGRect? {
        guard let element else { return nil }
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
