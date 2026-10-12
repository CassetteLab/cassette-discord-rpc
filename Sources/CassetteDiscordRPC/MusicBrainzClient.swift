import Foundation
import os

private let logger = Logger(
    subsystem: "fr.mathieu-dubart.cassette-discord-rpc",
    category: "MusicBrainzClient"
)

enum CachedCoverArt: Sendable {
    case unknown
    case missing
    case found(String)
}

actor MusicBrainzClient {

    private static let userAgent = "cassette-discord-rpc/1.0 (https://github.com/CassetteLab/cassette-discord-rpc)"
    /// MusicBrainz allows one request per second per client.
    private static let minimumInterval: Duration = .seconds(1)

    private enum Lookup {
        case found(String)
        case notFound
        case failed
    }

    /// Only definitive answers are cached: a network hiccup must not hide an album's artwork until restart.
    private var cache: [String: String?] = [:]
    private var nextRequestSlot: ContinuousClock.Instant = .now

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": MusicBrainzClient.userAgent]
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }()

    func cachedCoverArt(artist: String, album: String) -> CachedCoverArt {
        guard !album.isEmpty else { return .missing }
        guard let entry = cache[Self.cacheKey(artist: artist, album: album)] else { return .unknown }
        return entry.map(CachedCoverArt.found) ?? .missing
    }

    /// Resolves the album's front cover. Returns nil when there's none or the lookup failed or was cancelled.
    func coverArtURL(artist: String, album: String) async -> String? {
        guard !album.isEmpty else { return nil }
        let key = Self.cacheKey(artist: artist, album: album)
        if let cached = cache[key] {
            return cached
        }

        guard await waitForRequestSlot() else { return nil }

        switch await fetchReleaseMBID(artist: artist, album: album) {
        case .failed:
            return nil
        case .notFound:
            cache[key] = .some(nil)
            return nil
        case .found(let mbid):
            let url = "https://coverartarchive.org/release/\(mbid)/front"
            switch await verifyCoverArt(url: url) {
            case .found(let resolved):
                cache[key] = .some(resolved)
                return resolved
            case .notFound:
                cache[key] = .some(nil)
                return nil
            case .failed:
                return nil
            }
        }
    }

    private static func cacheKey(artist: String, album: String) -> String {
        "\(artist)|\(album)"
    }

    /// Reserves the next free slot before sleeping, so concurrent lookups can't burst past the limit.
    private func waitForRequestSlot() async -> Bool {
        let clock = ContinuousClock()
        let slot = max(clock.now, nextRequestSlot)
        nextRequestSlot = slot.advanced(by: Self.minimumInterval)
        do {
            try await clock.sleep(until: slot)
            return true
        } catch {
            return false
        }
    }

    private func fetchReleaseMBID(artist: String, album: String) async -> Lookup {
        guard var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/") else {
            return .failed
        }
        var query = "release:\"\(Self.luceneEscaped(album))\""
        if !artist.isEmpty {
            query += " AND artist:\"\(Self.luceneEscaped(artist))\""
        }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "fmt", value: "json")
        ]
        guard let url = components.url else { return .failed }

        do {
            let (data, response) = try await session.data(from: url)
            guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
                logger.warning("MusicBrainz search returned a non-200 status")
                return .failed
            }
            let result = try JSONDecoder().decode(MBReleaseSearch.self, from: data)
            return result.releases.first.map { .found($0.id) } ?? .notFound
        } catch {
            logger.warning("MusicBrainz search failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    private func verifyCoverArt(url: String) async -> Lookup {
        guard let requestURL = URL(string: url) else { return .failed }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200:
                return .found(url)
            case 404:
                return .notFound
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    private static func luceneEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private struct MBReleaseSearch: Decodable {
    struct Release: Decodable {
        let id: String
    }

    let releases: [Release]
}
