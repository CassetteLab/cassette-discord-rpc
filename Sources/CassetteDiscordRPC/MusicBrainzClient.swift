import Foundation
import os

private let logger = Logger(
    subsystem: "fr.mathieu-dubart.cassette-discord-rpc",
    category: "MusicBrainzClient"
)

actor MusicBrainzClient {

    private static let userAgent = "cassette-discord-rpc/1.0 (https://github.com/CassetteLab/cassette-discord-rpc)"
    private static let rateLimitNanoseconds: UInt64 = 1_000_000_000

    private var cache: [String: String?] = [:]
    private var lastRequestTime: ContinuousClock.Instant?

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": MusicBrainzClient.userAgent]
        return URLSession(configuration: config)
    }()

    func coverArtURL(artist: String, album: String) async -> String? {
        let cacheKey = "\(artist)|\(album)"

        if let cached = cache[cacheKey] {
            return cached
        }

        await enforceRateLimit()

        guard let mbid = await fetchReleaseMBID(artist: artist, album: album) else {
            cache[cacheKey] = .some(nil)
            return nil
        }

        let url = "https://coverartarchive.org/release/\(mbid)/front"
        let resolved = await verifyCoverArt(url: url)
        cache[cacheKey] = .some(resolved)
        return resolved
    }

    private func enforceRateLimit() async {
        if let lastTime = lastRequestTime {
            let elapsed = ContinuousClock().now - lastTime
            let elapsedNanos = UInt64(elapsed.components.seconds) * 1_000_000_000
                + UInt64(max(0, elapsed.components.attoseconds / 1_000_000_000))
            if elapsedNanos < Self.rateLimitNanoseconds {
                let remaining = Self.rateLimitNanoseconds - elapsedNanos
                try? await Task.sleep(nanoseconds: remaining)
            }
        }
        lastRequestTime = ContinuousClock().now
    }

    private func fetchReleaseMBID(artist: String, album: String) async -> String? {
        guard
            var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/")
        else { return nil }

        let query = "artist:\(artist) AND release:\(album)"
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "fmt", value: "json")
        ]

        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                logger.warning("MusicBrainz search returned non-200 status")
                return nil
            }

            let json = try JSONDecoder().decode(MBReleaseSearch.self, from: data)
            return json.releases.first?.id
        } catch {
            logger.warning("MusicBrainz search failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func verifyCoverArt(url: String) async -> String? {
        guard let reqURL = URL(string: url) else { return nil }
        do {
            var request = URLRequest(url: reqURL)
            request.httpMethod = "HEAD"
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }
            return url
        } catch {
            return nil
        }
    }
}

private struct MBReleaseSearch: Decodable {
    struct Release: Decodable {
        let id: String
    }
    let releases: [Release]
}
