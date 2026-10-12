import Foundation
import os

private let logger = Logger(
    subsystem: "fr.mathieu-dubart.cassette-discord-rpc",
    category: "Daemon"
)

actor Daemon {

    /// Extra time after a track's expected end before the presence is dropped.
    private static let expiryGrace: TimeInterval = 120
    /// Fallback when the duration is unknown (live streams).
    private static let unknownDurationTimeout: TimeInterval = 30 * 60

    private let port: UInt16
    private let discord: DiscordIPCClient
    private let musicBrainz = MusicBrainzClient()
    private let server: HTTPServer

    /// Bumped on every event, so a slow artwork lookup or a stale timer can't touch a newer track.
    private var generation = 0
    private var artworkTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?

    init(config: Configuration) {
        let discord = DiscordIPCClient(clientId: config.clientId)
        self.port = config.port
        self.discord = discord
        self.server = HTTPServer(port: config.port) { await discord.status() }
    }

    func run() async {
        logger.info("Daemon starting")
        await discord.start()

        let events: AsyncStream<NowPlayingEvent>
        do {
            events = try await server.start()
        } catch {
            exitWithFatalError(
                "cannot listen on port \(port): \(error). Is another instance already running? (launchctl list | grep cassette)"
            )
        }
        logger.info("Listening for Cassette on localhost:\(self.port, privacy: .public)")

        for await event in events {
            switch event {
            case .trackChanged(let info):
                await handleTrackChanged(info)
            case .playbackStopped:
                await handlePlaybackStopped()
            }
        }
    }

    private func handleTrackChanged(_ info: NowPlayingInfo) async {
        generation += 1
        let current = generation
        artworkTask?.cancel()
        artworkTask = nil

        let cached = await musicBrainz.cachedCoverArt(artist: info.artist, album: info.album)
        var coverArtURL: String?
        if case .found(let url) = cached {
            coverArtURL = url
        }

        // Show the track right away; the artwork follows once the lookup finishes.
        await discord.setActivity(ActivityPayload.make(from: info, coverArtURL: coverArtURL))
        scheduleExpiry(for: info)

        guard case .unknown = cached else { return }
        artworkTask = Task {
            guard let url = await self.musicBrainz.coverArtURL(artist: info.artist, album: info.album) else { return }
            await self.applyArtwork(url, for: info, generation: current)
        }
    }

    private func applyArtwork(_ url: String, for info: NowPlayingInfo, generation: Int) async {
        guard generation == self.generation else { return }
        await discord.setActivity(ActivityPayload.make(from: info, coverArtURL: url))
    }

    private func handlePlaybackStopped() async {
        generation += 1
        artworkTask?.cancel()
        artworkTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        logger.info("Playback stopped, clearing Discord presence")
        await discord.clearActivity()
    }

    /// Cassette posts on track changes and pauses, never while a track plays through,
    /// so the presence must outlive the track instead of timing out mid-song.
    private func scheduleExpiry(for info: NowPlayingInfo) {
        expiryTask?.cancel()
        let delay: TimeInterval
        if let end = info.trackEnd {
            delay = max(end.timeIntervalSinceNow, 0) + Self.expiryGrace
        } else {
            delay = Self.unknownDurationTimeout
        }
        let current = generation
        expiryTask = Task {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            await self.expire(generation: current)
        }
    }

    private func expire(generation: Int) async {
        guard generation == self.generation else { return }
        logger.info("No update from Cassette since the track should have ended, clearing presence")
        await discord.clearActivity()
    }
}
