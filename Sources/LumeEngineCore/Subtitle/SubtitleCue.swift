import Foundation

/// One subtitle cue on the engine timeline. Text-only for now; bitmap cues
/// (PGS/DVB) and full libass styling land with the subtitle pack (PLAN.md P5+).
public struct SubtitleCue: Sendable, Equatable, Identifiable {
    public let id: UInt64
    /// Engine µs.
    public let start: Int64
    public let end: Int64
    /// Plain display text (override tags stripped, line breaks preserved).
    public let text: String

    public init(id: UInt64, start: Int64, end: Int64, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Time-indexed cue container, safe for concurrent insert (decoder thread) and
/// query (UI tick). Cues are kept sorted by start time.
///
/// Cues outlive seeks on purpose — the store is a timeline, not a queue — so
/// the same packet reaches it again whenever the demuxer re-reads a range it
/// already delivered: a backward seek, or the seek that backfills a subtitle
/// track selected after the demuxer read past its packets. An identical cue
/// (same start, end, and text) is therefore dropped, or every re-read would
/// show its lines doubled.
public final class SubtitleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cues: [SubtitleCue] = []
    private var nextID: UInt64 = 0

    public init() {}

    func insert(start: Int64, end: Int64, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, end > start else { return }
        lock.lock()
        defer { lock.unlock() }
        // Insertion point by start time (cues arrive nearly sorted).
        var index = cues.count
        while index > 0 && cues[index - 1].start > start { index -= 1 }
        // Cues with the same start sit directly before the insertion point.
        var existing = index - 1
        while existing >= 0 && cues[existing].start == start {
            if cues[existing].end == end && cues[existing].text == trimmed { return }
            existing -= 1
        }
        cues.insert(SubtitleCue(id: nextID, start: start, end: end, text: trimmed), at: index)
        nextID += 1
    }

    /// All cues covering `time` (engine µs).
    public func activeCues(at time: Int64) -> [SubtitleCue] {
        lock.lock()
        defer { lock.unlock() }
        // Binary search for the first cue starting after `time`, then walk back.
        // Overlapping cues are rare and short-lived; a bounded backward scan is
        // simpler than an interval tree and plenty fast.
        var low = 0
        var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        var active: [SubtitleCue] = []
        var index = low - 1
        var scanned = 0
        while index >= 0 && scanned < 64 {
            let cue = cues[index]
            if cue.start <= time && time < cue.end {
                active.append(cue)
            }
            index -= 1
            scanned += 1
        }
        return active.sorted { $0.start < $1.start }
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cues.count
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        cues.removeAll()
    }
}
