import Foundation

/// The `activity` object of a Discord `SET_ACTIVITY` command.
///
/// Discord rejects the whole update when a single field breaks its schema (empty strings,
/// strings over 128 characters…), so every text field goes through `discordText(_:)` and
/// optional fields are omitted rather than sent empty.
struct ActivityPayload: Encodable, Sendable {

    struct Assets: Encodable, Sendable {
        let largeImage: String?
        let largeText: String?
        let smallImage: String?
        let smallText: String?

        private enum CodingKeys: String, CodingKey {
            case largeImage = "large_image"
            case largeText = "large_text"
            case smallImage = "small_image"
            case smallText = "small_text"
        }
    }

    /// Unix time in milliseconds.
    struct Timestamps: Encodable, Sendable {
        let start: Int64
        let end: Int64?
    }

    struct Button: Encodable, Sendable {
        let label: String
        let url: String
    }

    /// Shown as "Listening to <name>" in place of the Discord application's name.
    let name: String
    let type: Int
    let details: String
    let state: String?
    let assets: Assets
    let timestamps: Timestamps
    let buttons: [Button]
}

extension ActivityPayload {

    /// "Listening to …"
    private static let listeningType = 2
    private static let cassetteIconURL =
        "https://raw.githubusercontent.com/CassetteLab/cassette-discord-rpc/main/Assets/cassette-icon.png"
    private static let maxTextLength = 128

    static func make(from info: NowPlayingInfo, coverArtURL: String?) -> ActivityPayload {
        let hasCover = coverArtURL != nil
        let assets = Assets(
            largeImage: coverArtURL ?? cassetteIconURL,
            largeText: discordText(info.album),
            smallImage: hasCover ? cassetteIconURL : nil,
            smallText: hasCover ? "Cassette" : nil
        )
        let timestamps = Timestamps(
            start: milliseconds(info.trackStart),
            end: info.trackEnd.map(milliseconds)
        )
        let title = discordText(info.title) ?? "Unknown track"
        let name = discordText(info.artist).flatMap { discordText("\(title) - \($0)") } ?? title
        return ActivityPayload(
            name: name,
            type: listeningType,
            details: title,
            state: discordText(info.artist).flatMap { discordText("by \($0)") },
            assets: assets,
            timestamps: timestamps,
            buttons: [Button(label: "Get Cassette", url: "https://getcassette.app")]
        )
    }

    /// Fits a string into Discord's 2...128 character window, or returns nil when there's nothing to show.
    static func discordText(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Discord counts UTF-16 code units, like JavaScript.
        if trimmed.utf16.count == 1 {
            return trimmed + "\u{2800}" // Invisible padding up to the 2-character minimum.
        }
        guard trimmed.utf16.count > maxTextLength else { return trimmed }

        var truncated = ""
        for character in trimmed {
            if truncated.utf16.count + character.utf16.count > maxTextLength - 1 { break }
            truncated.append(character)
        }
        return truncated + "…"
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }
}
