import Foundation
import os

private let logger = Logger(
    subsystem: "fr.mathieu-dubart.cassette-discord-rpc",
    category: "Configuration"
)

struct Configuration: Decodable, Sendable {
    let clientId: String
    let port: UInt16

    private enum CodingKeys: String, CodingKey {
        case clientId, port
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientId = try container.decode(String.self, forKey: .clientId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 47832
    }
}

enum ConfigurationError: LocalizedError {
    case fileNotFound(String)
    case decodingFailed(String)
    case invalidClientId

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            "configuration file not found at \(path)"
        case .decodingFailed(let reason):
            "invalid configuration file: \(reason)"
        case .invalidClientId:
            "clientId must be the numeric Application ID from discord.com/developers/applications"
        }
    }
}

func loadConfiguration() throws -> Configuration {
    let configURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/cassette-discord-rpc/config.json")

    guard FileManager.default.fileExists(atPath: configURL.path) else {
        throw ConfigurationError.fileNotFound(configURL.path)
    }

    let config: Configuration
    do {
        let data = try Data(contentsOf: configURL)
        config = try JSONDecoder().decode(Configuration.self, from: data)
    } catch let error as DecodingError {
        throw ConfigurationError.decodingFailed(String(describing: error))
    }

    guard !config.clientId.isEmpty, config.clientId.allSatisfy({ $0.isASCII && $0.isNumber }) else {
        throw ConfigurationError.invalidClientId
    }

    logger.info("Configuration loaded")
    return config
}
