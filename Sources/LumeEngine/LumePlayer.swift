@preconcurrency import AVFoundation
import Foundation
import LumeEngineCore
import Observation

/// Main-actor facade over `PlayerSession` for UI code.
///
/// Observation is coalesced: `position` ticks at ~10 Hz on the main actor so a
/// SwiftUI scrubber can bind to it without re-rendering per frame (the lesson
/// from Lume's `PlaybackClock` isolation — PLAN.md §2.1). All engine work stays
/// off the main thread; this type only mirrors state.
@MainActor
@Observable
public final class LumePlayer {
    public enum State: Sendable, Equatable {
        case idle, opening, ready, buffering, playing, paused, ended, failed
    }

    // MARK: Observable UI state

    public private(set) var state: State = .idle
    /// Media-relative position in seconds, ~10 Hz.
    public private(set) var position: Double = 0
    public private(set) var duration: Double?
    public private(set) var mediaInfo: MediaInfo?
    public private(set) var lastError: EngineError?
    /// How many times the session saw no progress for `stallThreshold` seconds while it
    /// should have been playing (a dead source, a starved network, a silent decoder). A
    /// seekable source has already been sought to heal itself; a live one is the app's to
    /// recover (reconnect).
    public private(set) var stalls = 0
    /// True while the active decode path is VideoToolbox.
    public private(set) var isHardwareDecoding = false
    /// Text of the currently visible subtitle cue(s), `nil` when none.
    public private(set) var subtitleText: String?
    /// Bitmaps of the currently visible subtitle cue(s) — DVB, PGS and DVD
    /// subtitles, which have no text. `LumePlayerView` does not draw them:
    /// overlay each image at its `rect` scaled to the video's display area.
    public private(set) var subtitleImages: [SubtitleImage] = []

    public var audioTracks: [TrackInfo] { mediaInfo?.audioTracks ?? [] }
    public var subtitleTracks: [TrackInfo] { mediaInfo?.subtitleTracks ?? [] }

    public var rate: Float = 1.0 {
        didSet {
            let session = session
            let rate = rate
            Task { await session?.setRate(rate) }
        }
    }

    /// Output volume, 0...1, applied on top of the system volume. Kept across
    /// `load`, so a host can open a stream silent and ramp it up: audio that
    /// starts (or stops) mid-waveform at full level is heard as a click.
    public var volume: Float = 1.0 {
        didSet { session?.renderer.volume = volume }
    }

    /// Present this layer via `LumePlayerView` (SwiftUI) or add it to a view's
    /// layer tree directly (UIKit/AppKit).
    public var displayLayer: LumeDisplayLayer? { session?.renderer.displayLayer }

    /// tvOS: switch the TV to each loaded stream's refresh rate and dynamic
    /// range (Match Content) while it plays in a `LumePlayerView`, which
    /// supplies the window; `stop()` and the view going away hand the display
    /// back. Set before `load`. Off by default; ignored on other platforms.
    public var matchesDisplayCriteria = false {
        didSet {
            #if os(tvOS)
            if !matchesDisplayCriteria { displayMatcher.reset() }
            #endif
        }
    }

    #if os(tvOS)
    /// One per player, so loading the next stream does not hand the display
    /// back in between (see `DisplayCriteriaMatcher`).
    let displayMatcher = DisplayCriteriaMatcher()
    #endif

    private var session: PlayerSession?
    private var eventTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private let configuration: PlayerConfiguration

    public init(configuration: PlayerConfiguration = PlayerConfiguration()) {
        self.configuration = configuration
    }

    // MARK: Lifecycle

    /// The session's diagnostics (renderer health, buffering, bytes delivered), for an app's
    /// logs when something a person hears isn't in the events; nil with nothing loaded.
    public var diagnostics: PlayerSession.Diagnostics? {
        get async {
            guard let session else { return nil }
            return await session.diagnostics
        }
    }

    /// Opens `url`, replacing any previous session (each open is a fresh
    /// engine session — PLAN.md §3.1).
    public func load(url: String) async throws -> MediaInfo {
        await teardownSession()

        let session = PlayerSession(configuration: configuration)
        self.session = session
        session.renderer.volume = volume
        state = .opening

        eventTask = Task { [events = session.events] in
            for await event in events {
                self.handle(event: event)
            }
        }
        tickTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                await self.tick()
            }
        }

        do {
            let info = try await session.open(url: url)
            #if os(tvOS)
            // Before the app's play(): the start is held while the TV switches.
            if matchesDisplayCriteria { await displayMatcher.match(session) }
            #endif
            mediaInfo = info
            duration = info.duration.map(MediaTime.seconds)
            return info
        } catch {
            lastError = error as? EngineError
            state = .failed
            throw error
        }
    }

    public func play() {
        let session = session
        Task { await session?.play() }
    }

    public func pause() {
        let session = session
        Task { await session?.pause() }
    }

    public func seek(to seconds: Double) {
        let session = session
        Task { await session?.seek(to: seconds) }
    }

    public func skip(by seconds: Double) {
        seek(to: max(0, position + seconds))
    }

    public func selectAudioTrack(_ index: Int32) {
        let session = session
        Task { await session?.selectAudioTrack(index) }
    }

    /// `nil` disables subtitles.
    public func selectSubtitleTrack(_ index: Int32?) {
        let session = session
        Task { await session?.selectSubtitleTrack(index) }
        if index == nil {
            subtitleText = nil
            subtitleImages = []
        }
    }

    /// The picked subtitle's cues the engine holds that show at any moment
    /// from `start` through `end`, each with its own times, in seconds on
    /// `position`'s clock: for a host that draws the lines itself and moves
    /// them against the picture (a subtitle running early or late), which
    /// `subtitleText` and `subtitleImages`, saying only what shows now, can't.
    ///
    /// What is held behind the playhead is every cue decoded since the track
    /// was picked, within the store's limits (thousands of text cues; a
    /// minute or more of full-HD bitmaps). Ahead of it, only what has been
    /// decoded: an embedded track's packets are decoded as the demuxer reads
    /// them, so a file's are held up to `packetReadAhead` ahead once the
    /// packet queues have filled (less just after a start or a seek), and a
    /// live stream's only as far as the source has delivered past the
    /// picture. Closed captions come out of decoded video, so they are held a
    /// few frames ahead at most; an external file is held whole.
    public func subtitleCues(from start: Double, through end: Double) -> [TimedSubtitleCue] {
        guard let session, let origin = mediaInfo?.startTime, start.isFinite, end.isFinite else { return [] }
        return session.subtitles
            .cues(from: origin + MediaTime.microseconds(start), through: origin + MediaTime.microseconds(end))
            .map { TimedSubtitleCue($0, origin: origin) }
    }

    public func loadExternalSubtitles(url: String) async throws {
        guard let session else {
            throw EngineError(code: .invalidState, message: "no media loaded")
        }
        try await session.loadExternalSubtitles(url: url)
    }

    public func stop() async {
        #if os(tvOS)
        displayMatcher.reset()
        #endif
        await teardownSession()
        state = .idle
        position = 0
        mediaInfo = nil
        duration = nil
        subtitleText = nil
        subtitleImages = []
    }

    // MARK: Internals

    private func teardownSession() async {
        eventTask?.cancel()
        tickTask?.cancel()
        eventTask = nil
        tickTask = nil
        if let session {
            await session.shutdown()
        }
        session = nil
    }

    private func handle(event: PlayerEvent) {
        switch event {
        case .stateChanged(let sessionState):
            state = Self.mirror(sessionState)
        case .opened(let info):
            mediaInfo = info
            duration = info.duration.map(MediaTime.seconds)
        case .decoderDowngraded:
            isHardwareDecoding = false
        case .didSeek(let position):
            self.position = position
        case .stalled:
            // The app's to recover: a live source that stays connected and sends nothing
            // never errors, so this is its only sign of death (HomeTV reconnects on it).
            stalls += 1
        case .error(let error):
            lastError = error
        }
    }

    private func tick() async {
        guard let session else { return }
        position = await session.position
        // Tracks can turn up after open (closed captions in the video).
        if let mediaInfo, let current = await session.mediaInfo,
           current.tracks.count != mediaInfo.tracks.count {
            self.mediaInfo = current
        }

        let now = session.renderer.currentTime
        if MediaTime.isValid(now) {
            let cues = session.subtitles.activeCues(at: now)
            let text = cues.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
            subtitleText = text.isEmpty ? nil : text
            let images = cues.flatMap(\.images)
            if images != subtitleImages { subtitleImages = images }
        } else {
            subtitleText = nil
            if !subtitleImages.isEmpty { subtitleImages = [] }
        }
    }

    private static func mirror(_ state: PlayerSession.State) -> State {
        switch state {
        case .idle: .idle
        case .opening: .opening
        case .ready: .ready
        case .buffering: .buffering
        case .playing: .playing
        case .paused: .paused
        case .ended: .ended
        case .failed: .failed
        }
    }
}

/// A subtitle cue with its times in seconds on `LumePlayer.position`'s clock,
/// as `LumePlayer.subtitleCues(from:through:)` hands it over.
public struct TimedSubtitleCue: Sendable, Equatable, Identifiable {
    /// The cue's own, for the session: it keeps it while held, though its end
    /// can come earlier (the next update ends an open one). An update that
    /// replaces it at the same start is a new cue with a new id.
    public let id: UInt64
    public let start: Double
    public let end: Double
    /// Plain display text; empty for a bitmap cue.
    public let text: String
    /// Bitmaps (DVB, PGS, DVD), placed as `SubtitleImage.rect` says.
    public let images: [SubtitleImage]

    public init(id: UInt64, start: Double, end: Double, text: String, images: [SubtitleImage] = []) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.images = images
    }

    init(_ cue: SubtitleCue, origin: Int64) {
        self.init(
            id: cue.id,
            start: MediaTime.seconds(cue.start - origin),
            end: MediaTime.seconds(cue.end - origin),
            text: cue.text,
            images: cue.images
        )
    }
}
