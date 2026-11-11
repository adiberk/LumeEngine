import Foundation
import Testing
@testable import LumeEngine
@testable import LumeEngineCore

@Suite("LumePlayer facade", .serialized)
struct LumePlayerTests {
    @Test("load → play mirrors state and position on the main actor", .timeLimit(.minutes(1)))
    @MainActor
    func facadePlayback() async throws {
        var configuration = PlayerConfiguration()
        configuration.muted = true
        configuration.bufferTarget = 0.3
        let player = LumePlayer(configuration: configuration)

        let info = try await player.load(url: try Fixtures.path("basic.mp4"))
        #expect(info.videoTracks.count == 1)
        #expect(player.duration.map { abs($0 - 10) < 0.5 } == true)
        #expect(player.displayLayer != nil)

        player.play()
        let deadline = Date(timeIntervalSinceNow: 10)
        while player.state != .playing && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(player.state == .playing)

        // The facade mirrors position as a low-rate observation, so poll for the
        // tick instead of assuming a fixed window produced one — a stalled
        // sampler is not a stalled clock.
        let tickDeadline = Date(timeIntervalSinceNow: 10)
        while player.position <= 0.5 && Date() < tickDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(player.position > 0.5, "observable position should tick, got \(player.position)")

        player.seek(to: 6)
        let seekDeadline = Date(timeIntervalSinceNow: 10)
        while player.position < 5.5 && Date() < seekDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(player.position >= 5.5 && player.position <= 8.5)

        await player.stop()
        #expect(player.state == .idle)
    }

    @Test("load replaces the previous session cleanly", .timeLimit(.minutes(1)))
    @MainActor
    func reload() async throws {
        var configuration = PlayerConfiguration()
        configuration.muted = true
        configuration.bufferTarget = 0.3
        let player = LumePlayer(configuration: configuration)

        _ = try await player.load(url: try Fixtures.path("basic.mp4"))
        player.play()
        try await Task.sleep(for: .milliseconds(500))

        // Second load must tear down the first pipeline (no leaked threads
        // keeping the old clock alive) and start fresh.
        let info = try await player.load(url: try Fixtures.path("multitrack.mkv"))
        #expect(info.audioTracks.count == 2)
        player.play()

        let deadline = Date(timeIntervalSinceNow: 10)
        while player.state != .playing && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(player.state == .playing)
        #expect(player.position < 9, "position must belong to the new session")

        await player.stop()
    }

    /// A host drawing the lines itself gets the cues ahead of and behind the
    /// playhead with their own times on `position`'s clock, so it can show
    /// them earlier or later than the file has them. The 8 s fixture is read
    /// whole at once (the read-ahead is 15 s), so both of its cues are held
    /// from the start: 1–3 s "Hello from LumeEngine", 4–6 s "Second cue".
    @Test("the picked subtitle's cues come with their times on position's clock", .timeLimit(.minutes(1)))
    @MainActor
    func timedSubtitleCues() async throws {
        var configuration = PlayerConfiguration()
        configuration.muted = true
        configuration.bufferTarget = 0.3
        let player = LumePlayer(configuration: configuration)
        #expect(player.subtitleCues(from: -60, through: 60).isEmpty, "nothing loaded")

        let info = try await player.load(url: try Fixtures.path("multitrack.mkv"))
        let track = try #require(info.subtitleTracks.first)
        player.selectSubtitleTrack(track.index)
        player.play()

        let deadline = Date(timeIntervalSinceNow: 10)
        while player.subtitleCues(from: player.position - 60, through: player.position + 60).count < 2 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let cues = player.subtitleCues(from: player.position - 60, through: player.position + 60)
        #expect(cues.map(\.text) == ["Hello from LumeEngine", "Second cue"])
        #expect(cues.map { ($0.start * 10).rounded() / 10 } == [1, 4], "starts on position's clock")
        #expect(cues.map { ($0.end * 10).rounded() / 10 } == [3, 6])
        #expect(player.subtitleCues(from: 3.5, through: 3.9).isEmpty, "the gap between them")
        #expect(player.subtitleCues(from: 2, through: 2).map(\.text) == ["Hello from LumeEngine"])

        await player.stop()
        #expect(player.subtitleCues(from: -60, through: 60).isEmpty, "stopped")
    }
}
