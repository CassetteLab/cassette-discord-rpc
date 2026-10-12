import Foundation

/// Body of `POST /now-playing`, as sent by Cassette.
struct NowPlayingInfo: Sendable, Decodable {
    let title: String
    let artist: String
    let album: String
    /// Track length in seconds; 0 for live streams.
    let duration: Double
    /// Unix time (seconds) at which playback started or resumed.
    let startedAt: Double
    /// Playback position in seconds at `startedAt`. Optional: current Cassette builds don't send it.
    let position: Double?

    private enum CodingKeys: String, CodingKey {
        case title, artist, album, duration, startedAt, position
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try container.decodeIfPresent(String.self, forKey: .album) ?? ""
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        startedAt = try container.decodeIfPresent(Double.self, forKey: .startedAt) ?? Date().timeIntervalSince1970
        position = try container.decodeIfPresent(Double.self, forKey: .position)
    }
}

extension NowPlayingInfo {
    /// When the track itself started, accounting for a resume mid-track.
    var trackStart: Date {
        // Accept milliseconds too, in case a client sends them.
        var seconds = startedAt > 100_000_000_000 ? startedAt / 1000 : startedAt
        if !seconds.isFinite || seconds <= 0 {
            seconds = Date().timeIntervalSince1970
        }
        let offset = position.flatMap { $0.isFinite ? max($0, 0) : nil } ?? 0
        return Date(timeIntervalSince1970: seconds - offset)
    }

    /// When the track should end, if its duration is known.
    var trackEnd: Date? {
        guard duration.isFinite, duration > 0 else { return nil }
        return trackStart.addingTimeInterval(duration)
    }
}
