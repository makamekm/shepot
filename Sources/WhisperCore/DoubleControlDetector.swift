import Foundation

public enum ControlShortcutAction: Equatable {
    case start, stop
}

/// Recognizes two complete, short, isolated Control taps. Uses event timestamps.
public struct DoubleControlDetector {
    private var pressedAt: TimeInterval?
    private var lastRelease: TimeInterval?
    public var maximumTapDuration: TimeInterval = 0.32
    public var maximumGap: TimeInterval = 0.38

    public init() {}

    public mutating func reset() {
        pressedAt = nil
        lastRelease = nil
    }

    /// Starting requires two complete taps; an active recording stops on Control down.
    public mutating func action(controlDown: Bool, otherModifierDown: Bool, timestamp: TimeInterval, isRecording: Bool) -> ControlShortcutAction? {
        if isRecording {
            reset()
            return controlDown && !otherModifierDown ? .stop : nil
        }
        return flagsChanged(controlDown: controlDown, otherModifierDown: otherModifierDown, timestamp: timestamp) ? .start : nil
    }

    public mutating func flagsChanged(controlDown: Bool, otherModifierDown: Bool, timestamp: TimeInterval) -> Bool {
        guard !otherModifierDown else { reset(); return false }
        if controlDown {
            if pressedAt == nil { pressedAt = timestamp }
            return false
        }
        guard let press = pressedAt else { return false }
        pressedAt = nil
        guard timestamp >= press, timestamp - press <= maximumTapDuration else {
            lastRelease = nil
            return false
        }
        if let previous = lastRelease, press >= previous, press - previous <= maximumGap {
            lastRelease = nil
            return true
        }
        lastRelease = timestamp
        return false
    }
}
