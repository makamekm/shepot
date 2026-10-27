import AVFoundation
import Speech

enum SpeechWindowPolicy {
    static let duration: TimeInterval = 40
    static let overlap: TimeInterval = 3
    static let finalizationGrace: TimeInterval = 1.2
    static func shouldRotate(bufferedDuration: TimeInterval, requestAge: TimeInterval) -> Bool {
        bufferedDuration >= duration && requestAge >= 1
    }
}

enum TranscriptText {
    private static func key(_ token: Substring) -> String {
        String(token).precomposedStringWithCanonicalMapping.lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
    }
    static func removingPrefix(_ prefix: String, from value: String) -> String? {
        let old = prefix.split(whereSeparator: \.isWhitespace), new = value.split(whereSeparator: \.isWhitespace)
        guard !old.isEmpty, new.count >= old.count,
              zip(old, new).allSatisfy({ key($0.0) == key($0.1) }) else { return nil }
        guard new.count > old.count else { return "" }
        return String(value[new[old.count].startIndex...])
    }
    static func isNewPassage(_ value: String, after previous: String) -> Bool {
        let old = previous.split(whereSeparator: \.isWhitespace)
        let new = value.split(whereSeparator: \.isWhitespace)
        guard old.count >= 6, new.count >= 3 else { return false }
        let oldKeys = Set(old.map(key)), newKeys = Set(new.map(key))
        return oldKeys.intersection(newKeys).count * 100 < min(oldKeys.count, newKeys.count) * 45
    }
    static func appending(_ next: String, to previous: String, audioOverlap: Bool) -> String {
        guard !previous.isEmpty else { return next }
        guard !next.isEmpty else { return previous }
        var addition = next
        if audioOverlap {
            let tail = previous.suffix(4096).split(whereSeparator: \.isWhitespace).suffix(32)
            let head = next.split(whereSeparator: \.isWhitespace)
            let count = min(tail.count, head.count)
            if count > 0 {
                for size in stride(from: count, through: 1, by: -1) {
                    if zip(tail.suffix(size), head.prefix(size)).allSatisfy({ key($0.0) == key($0.1) }) {
                        addition = head.count == size ? "" : String(next[head[size].startIndex...])
                        break
                    }
                }
            }
        }
        return addition.isEmpty ? previous : previous + " " + addition
    }
}

/// Completed windows and detected partial resets never overwrite earlier text.
struct SpeechTranscript {
    private(set) var committed: [String] = []
    private(set) var current = ""
    private var completedText = ""
    private var frozenInRequest: [String] = []
    private var recoveryBaseline = ""
    private var firstAudioTime: TimeInterval?
    private var lastAudioTime: TimeInterval?
    private var audioOverlap = false
    var activeText: String { (frozenInRequest + [current]).filter { !$0.isEmpty }.joined(separator: " ") }
    var text: String { TranscriptText.appending(activeText, to: completedText, audioOverlap: audioOverlap) }

    @discardableResult mutating func accept(_ value: String, audioStart: TimeInterval? = nil, audioEnd: TimeInterval? = nil,
                                           audioTimesReliable: Bool = true) -> Bool {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        var time = audioTimesReliable ? audioStart : nil
        let frozen = frozenInRequest.joined(separator: " ")
        if !frozen.isEmpty, TranscriptText.removingPrefix(value, from: frozen) != nil { return false }
        if let remaining = TranscriptText.removingPrefix(frozen, from: value) {
            guard !remaining.isEmpty else { return false }
            value = remaining; time = nil
        }
        if !recoveryBaseline.isEmpty && value.count < recoveryBaseline.count { return false }
        recoveryBaseline = ""
        let oldWords = current.split(whereSeparator: \.isWhitespace).count
        let newWords = value.split(whereSeparator: \.isWhitespace).count
        let advancedAudio: Bool
        if let time, let firstAudioTime, let lastAudioTime {
            advancedAudio = time > firstAudioTime + 1 && time >= lastAudioTime - 0.05
        } else { advancedAudio = false }
        let shrank = oldWords >= 6 && (value.count < current.count * 3 / 5 || newWords + 3 < oldWords)
        var protectedPrevious = false
        if advancedAudio {
            frozenInRequest.append(current); current = ""; protectedPrevious = true
        } else if shrank || TranscriptText.isNewPassage(value, after: current) {
            // A stale/shorter cumulative hypothesis must not erase the visible draft.
            if TranscriptText.removingPrefix(value, from: current) != nil { return false }
            frozenInRequest.append(current); current = ""; protectedPrevious = true
        }
        current = value
        if let time { firstAudioTime = time }
        if audioTimesReliable, let end = audioEnd, let start = audioStart, end > start + 0.1 { lastAudioTime = end }
        return protectedPrevious
    }
    mutating func prepareRecovery() { recoveryBaseline = current }
    mutating func commit(overlapNext: Bool = false) {
        let full = text
        if !full.isEmpty { committed.append(activeText) }
        completedText = full
        current = ""; frozenInRequest = []; recoveryBaseline = ""; firstAudioTime = nil; lastAudioTime = nil
        audioOverlap = overlapNext
    }
}

/// A bounded RAM-only replay buffer. The audio tap and recognizer share this feed.
final class SpeechAudioFeed: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.shepot.speech-feed")
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var buffers: [AVAudioPCMBuffer] = []
    private var duration: TimeInterval = 0
    var bufferedDuration: TimeInterval { queue.sync { duration } }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let copy = Self.copy(buffer) else { return }
        // Recognition/replay must never block the real-time microphone callback.
        queue.async { [self] in
            buffers.append(copy)
            duration += Double(copy.frameLength) / copy.format.sampleRate
            while duration > 60, buffers.count > 1 {
                let first = buffers.removeFirst()
                duration -= Double(first.frameLength) / first.format.sampleRate
            }
            request?.append(copy)
        }
    }
    func attach(_ request: SFSpeechAudioBufferRecognitionRequest, replay: Bool) {
        queue.sync {
            self.request = request
            if replay { for buffer in buffers { request.append(buffer) } }
            else { buffers.removeAll(keepingCapacity: true); duration = 0 }
        }
    }
    /// End the old request, retaining a short context plus all audio arriving during handover.
    func rotate(retaining seconds: TimeInterval) {
        queue.sync {
            request?.endAudio(); request = nil
            var retained: [AVAudioPCMBuffer] = [], retainedDuration: TimeInterval = 0
            for buffer in buffers.reversed() {
                if retainedDuration >= seconds { break }
                retained.append(buffer)
                retainedDuration += Double(buffer.frameLength) / buffer.format.sampleRate
            }
            buffers = retained.reversed(); duration = retainedDuration
        }
    }
    func detach() { queue.sync { request = nil } }
    func endAudio() { queue.sync { request?.endAudio(); request = nil } }
    func reset() { queue.sync { request = nil; buffers.removeAll(); duration = 0 } }
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        for (source, destination) in zip(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList), UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)) {
            if let sourceData = source.mData, let destinationData = destination.mData {
                memcpy(destinationData, sourceData, min(Int(source.mDataByteSize), Int(destination.mDataByteSize)))
            }
        }
        return copy
    }
}
