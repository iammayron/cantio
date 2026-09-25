import XCTest
@testable import Cantio

@MainActor
final class MockPlaybackSource: PlaybackSource {
    let events: AsyncStream<NowPlaying?>
    let continuation: AsyncStream<NowPlaying?>.Continuation

    init() {
        var cont: AsyncStream<NowPlaying?>.Continuation!
        self.events = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    func yield(_ np: NowPlaying?) {
        continuation.yield(np)
    }

    func finish() {
        continuation.finish()
    }

    // PlaybackSource transport stubs — unused in LyricsStore tests but
    // required by the protocol.
    private(set) var playPauseCalls = 0
    private(set) var previousCalls = 0
    private(set) var nextCalls = 0
    private(set) var seekTargets: [Double] = []
    private(set) var volumeTargets: [Int] = []
    private(set) var shuffleTargets: [Bool] = []
    private(set) var repeatTargets: [Bool] = []
    var nextErrorToInject: Error?

    func playPause(onError: @escaping @MainActor (Error) -> Void) {
        playPauseCalls += 1
        if let err = nextErrorToInject { nextErrorToInject = nil; onError(err) }
    }
    func previousTrack(onError: @escaping @MainActor (Error) -> Void) {
        previousCalls += 1
        if let err = nextErrorToInject { nextErrorToInject = nil; onError(err) }
    }
    func nextTrack(onError: @escaping @MainActor (Error) -> Void) {
        nextCalls += 1
        if let err = nextErrorToInject { nextErrorToInject = nil; onError(err) }
    }
    func seek(to seconds: Double, onError: @escaping @MainActor (Error) -> Void) {
        seekTargets.append(seconds)
        if let err = nextErrorToInject { nextErrorToInject = nil; onError(err) }
    }
    func setVolume(_ volume: Int, onError: @escaping @MainActor (Error) -> Void) {
        volumeTargets.append(volume)
        if let err = nextErrorToInject { nextErrorToInject = nil; onError(err) }
    }
    func setShuffling(_ on: Bool, onError: @escaping @MainActor (Error) -> Void) {
        shuffleTargets.append(on)
        if let err = nextErrorToInject { nextErrorToInject = nil; onError(err) }
    }
    func setRepeating(_ on: Bool, onError: @escaping @MainActor (Error) -> Void) {
        repeatTargets.append(on)
        if let err = nextErrorToInject { nextErrorToInject = nil; onError(err) }
    }
}

actor StubLyricsProvider: LyricsProvider {
    private(set) var callCount: Int = 0
    private(set) var receivedTrackIds: [String] = []
    private var responses: [String: LyricsState] = [:]
    private var defaultResponse: LyricsState = .notFound
    private var delayNanos: UInt64 = 0

    func setResponse(_ state: LyricsState, forTrackId id: String) {
        responses[id] = state
    }

    func setDefault(_ state: LyricsState) {
        defaultResponse = state
    }

    func setDelay(nanos: UInt64) {
        delayNanos = nanos
    }

    func fetch(track: NowPlaying) async -> LyricsState {
        callCount += 1
        receivedTrackIds.append(track.trackId)
        if delayNanos > 0 {
            try? await Task.sleep(nanoseconds: delayNanos)
        }
        return responses[track.trackId] ?? defaultResponse
    }
}

@MainActor
final class LyricsStoreTests: XCTestCase {
    private var tempDir: URL!
    private var cache: LyricsCache!
    private var source: MockPlaybackSource!
    private var provider: StubLyricsProvider!
    private var store: LyricsStore!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cantio-store-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        cache = LyricsCache(directory: tempDir)
        source = MockPlaybackSource()
        provider = StubLyricsProvider()
        store = LyricsStore(service: provider, cache: cache)
        store.bind(to: source)
    }

    override func tearDown() async throws {
        store.stop()
        source.finish()
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private func makeNowPlaying(id: String) -> NowPlaying {
        NowPlaying(trackId: id, title: "t-\(id)", artist: "a", album: "al",
                   durationSeconds: 200, positionSeconds: 0, state: .playing)
    }

    /// Wait until `condition` becomes true or `timeout` elapses. Polls the
    /// MainActor every 5 ms.
    private func waitUntil(timeout: TimeInterval = 0.8,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func test_handle_newTrack_cacheMiss_callsProviderAndCachesResult() async {
        let lines = [LyricLine(timestamp: 0, text: "hello")]
        await provider.setResponse(.synced(lines), forTrackId: "trk-1")

        source.yield(makeNowPlaying(id: "trk-1"))

        await waitUntil { self.store.state == .synced(lines) }

        XCTAssertEqual(store.state, .synced(lines))
        XCTAssertEqual(store.trackId, "trk-1")
        let count = await provider.callCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(cache.load(trackId: "trk-1"),
                       LyricsCache.Entry(synced: lines, plain: nil))
    }

    func test_handle_sameTrackIdAgain_doesNotRefetch() async {
        let lines = [LyricLine(timestamp: 0, text: "x")]
        await provider.setResponse(.synced(lines), forTrackId: "trk-2")

        source.yield(makeNowPlaying(id: "trk-2"))
        await waitUntil { self.store.state == .synced(lines) }
        source.yield(makeNowPlaying(id: "trk-2"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        let count = await provider.callCount
        XCTAssertEqual(count, 1)
    }

    func test_handle_cacheHit_skipsProviderCall() async {
        // Cache loader rejects single-line / placeholder-stamp entries, so
        // give it two distinct stamps spanning >1s to mirror a real upload.
        let lines = [
            LyricLine(timestamp: 0, text: "cached"),
            LyricLine(timestamp: 2.5, text: "again"),
        ]
        cache.save(LyricsCache.Entry(synced: lines, plain: nil), trackId: "trk-3")

        source.yield(makeNowPlaying(id: "trk-3"))

        await waitUntil { self.store.state == .synced(lines) }

        XCTAssertEqual(store.state, .synced(lines))
        let count = await provider.callCount
        XCTAssertEqual(count, 0)
    }

    func test_handle_nilEvent_resetsToIdle() async {
        let lines = [LyricLine(timestamp: 0, text: "y")]
        await provider.setResponse(.synced(lines), forTrackId: "trk-4")

        source.yield(makeNowPlaying(id: "trk-4"))
        await waitUntil { self.store.state == .synced(lines) }

        source.yield(nil)
        await waitUntil { self.store.state == .idle }

        XCTAssertEqual(store.state, .idle)
        XCTAssertNil(store.trackId)
    }

    func test_handle_trackChangesMidFetch_dropsLateResult() async {
        let aLines = [LyricLine(timestamp: 0, text: "A")]
        let bLines = [LyricLine(timestamp: 0, text: "B")]
        await provider.setResponse(.synced(aLines), forTrackId: "trk-A")
        await provider.setResponse(.synced(bLines), forTrackId: "trk-B")
        await provider.setDelay(nanos: 200_000_000)

        source.yield(makeNowPlaying(id: "trk-A"))
        try? await Task.sleep(nanoseconds: 20_000_000)
        source.yield(makeNowPlaying(id: "trk-B"))

        await waitUntil(timeout: 1.0) { self.store.state == .synced(bLines) }

        XCTAssertEqual(store.state, .synced(bLines))
        XCTAssertEqual(store.trackId, "trk-B")
        let count = await provider.callCount
        XCTAssertEqual(count, 2)
    }

    func test_handle_providerReturnsNotFound_storesEmptyEntry() async {
        await provider.setResponse(.notFound, forTrackId: "trk-5")

        source.yield(makeNowPlaying(id: "trk-5"))

        await waitUntil { self.store.state == .notFound }

        XCTAssertEqual(store.state, .notFound)
        XCTAssertEqual(cache.load(trackId: "trk-5"),
                       LyricsCache.Entry(synced: nil, plain: nil))
    }

    func test_handle_providerReturnsError_doesNotCache() async {
        await provider.setResponse(.error("boom"), forTrackId: "trk-6")

        source.yield(makeNowPlaying(id: "trk-6"))

        await waitUntil { self.store.state == .error("boom") }

        XCTAssertEqual(store.state, .error("boom"))
        XCTAssertNil(cache.load(trackId: "trk-6"))
    }
}
