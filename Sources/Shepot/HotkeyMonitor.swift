import AppKit
import WhisperCore

@MainActor
final class HotkeyMonitor {
    private var global: Any?
    private var local: Any?
    private var detector = DoubleControlDetector()
    var isRecording: (() -> Bool)?
    var isProcessing: (() -> Bool)?
    var onSkipEditing: (() -> Void)?
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onEscape: (() -> Void)?
    func start() {
        guard global == nil, local == nil else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }
    func stop() {
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil; local = nil; detector.reset()
    }
    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            detector.reset()
            if event.keyCode == 53 { onEscape?() }
            return
        }
        guard event.keyCode == 59 || event.keyCode == 62 else {
            detector.reset()
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let other = !flags.intersection([.command, .option, .shift, .function]).isEmpty
        if isProcessing?() == true {
            detector.reset()
            if flags.contains(.control), !other { onSkipEditing?() }
            return
        }
        switch detector.action(controlDown: flags.contains(.control), otherModifierDown: other, timestamp: event.timestamp, isRecording: isRecording?() == true) {
        case .start: onStart?()
        case .stop: onStop?()
        case nil: break
        }
    }
}
