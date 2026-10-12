import Foundation
import os

private let logger = Logger(
    subsystem: "fr.mathieu-dubart.cassette-discord-rpc",
    category: "DiscordIPCClient"
)

private enum Opcode: UInt32 {
    case handshake = 0
    case frame = 1
    case close = 2
    case ping = 3
    case pong = 4
}

/// Snapshot served on `GET /health`.
struct DiscordStatus: Encodable, Sendable {
    let discord: String
    let lastError: String?
    let presenceActive: Bool
}

/// Talks to the local Discord (or Vesktop) client over its IPC socket.
///
/// A single supervisor task owns the connection: find a live socket, handshake, wait for READY,
/// read every frame Discord sends (errors, pings, close), and reconnect with backoff whenever the
/// connection drops — including when Discord restarts itself after an update. The presence is
/// kept as desired state and replayed on every READY, so an update that arrives while Discord is
/// down shows up as soon as it is back.
actor DiscordIPCClient {

    private enum State: String {
        case searching
        case connecting
        case ready
    }

    private static let initialRetryDelay: Duration = .seconds(2)
    private static let maxRetryDelay: Duration = .seconds(60)
    private static let maxFrameSize: UInt32 = 1 << 20
    private static let noSocketMessage = "No Discord IPC socket found. Is Discord or Vesktop running?"

    private let clientId: String
    private var supervisor: Task<Void, Never>?
    private var socket: IPCSocket?
    private var state: State = .searching
    private var lastError: String?
    private var desiredActivity: ActivityPayload?

    init(clientId: String) {
        self.clientId = clientId
    }

    // MARK: - Public API

    func start() {
        guard supervisor == nil else { return }
        supervisor = Task { await self.supervise() }
    }

    func setActivity(_ activity: ActivityPayload) {
        desiredActivity = activity
        pushDesiredActivity()
    }

    func clearActivity() {
        desiredActivity = nil
        pushDesiredActivity()
    }

    func status() -> DiscordStatus {
        DiscordStatus(discord: state.rawValue, lastError: lastError, presenceActive: desiredActivity != nil)
    }

    // MARK: - Connection lifecycle

    private func supervise() async {
        var delay = Self.initialRetryDelay
        while !Task.isCancelled {
            if await runSession() {
                delay = Self.initialRetryDelay
            }
            logger.info("Retrying Discord IPC in \(delay.components.seconds, privacy: .public)s")
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, Self.maxRetryDelay)
        }
    }

    /// One connection, from connect to drop. Returns whether Discord accepted the handshake.
    private func runSession() async -> Bool {
        guard let socket = connectToDiscord() else { return false }
        self.socket = socket
        state = .connecting

        var accepted = false
        do {
            try write(.handshake, Handshake(version: 1, clientId: clientId))
            frames: for try await frame in Self.frames(from: socket) {
                switch Opcode(rawValue: frame.opcode) {
                case .frame:
                    if handleMessage(frame.payload) { accepted = true }
                case .ping:
                    try writeRaw(.pong, frame.payload)
                case .close:
                    let reason = Self.describeClose(frame.payload)
                    lastError = reason
                    logger.error("Discord closed the connection: \(reason, privacy: .public)")
                    break frames
                case .handshake, .pong, .none:
                    break
                }
            }
        } catch {
            logger.warning("Discord IPC connection lost: \(String(describing: error), privacy: .public)")
        }

        socket.shutdown()
        self.socket = nil
        state = .searching
        return accepted
    }

    private func connectToDiscord() -> IPCSocket? {
        let candidates = Self.socketCandidates()
        guard !candidates.isEmpty else {
            if lastError != Self.noSocketMessage {
                logger.notice("\(Self.noSocketMessage, privacy: .public)")
            }
            lastError = Self.noSocketMessage
            return nil
        }

        for path in candidates {
            do {
                let socket = try IPCSocket.connect(path: path)
                logger.info("Connected to Discord IPC at \(path, privacy: .public)")
                return socket
            } catch {
                // Usually a stale socket file left behind by a Discord that crashed or was force-quit.
                logger.debug("Skipping \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        let message = "Discord IPC sockets exist but none accepted a connection"
        lastError = message
        logger.warning("\(message, privacy: .public)")
        return nil
    }

    // MARK: - Messages

    /// Returns true when the message is Discord's READY.
    private func handleMessage(_ payload: Data) -> Bool {
        guard let message = try? JSONDecoder().decode(IncomingMessage.self, from: payload) else {
            logger.debug("Ignoring undecodable Discord frame")
            return false
        }

        switch message.evt {
        case "READY":
            state = .ready
            lastError = nil
            logger.info("Discord accepted the handshake, presence is live")
            pushDesiredActivity()
            return true
        case "ERROR":
            let code = message.data?.code.map(String.init) ?? "?"
            let reason = "\(message.cmd ?? "command") rejected (\(code)): \(message.data?.message ?? "no message")"
            lastError = reason
            logger.error("Discord \(reason, privacy: .public)")
            return false
        default:
            return false
        }
    }

    private func pushDesiredActivity() {
        guard state == .ready else {
            logger.debug("Discord not ready yet, presence update queued")
            return
        }
        let command = SetActivityCommand(
            args: .init(pid: ProcessInfo.processInfo.processIdentifier, activity: desiredActivity),
            nonce: UUID().uuidString
        )
        do {
            try write(.frame, command)
        } catch {
            logger.warning("Failed to send presence: \(String(describing: error), privacy: .public)")
            // The reader notices the dead socket and the supervisor reconnects, replaying this update.
            socket?.shutdown()
        }
    }

    private func write<Message: Encodable>(_ opcode: Opcode, _ message: Message) throws {
        try writeRaw(opcode, JSONEncoder().encode(message))
    }

    private func writeRaw(_ opcode: Opcode, _ payload: Data) throws {
        guard let socket else { throw IPCSocket.SocketError.closedByPeer }
        try socket.write(Self.encodeFrame(opcode, payload))
    }

    // MARK: - Framing

    private struct Frame: Sendable {
        let opcode: UInt32
        let payload: Data
    }

    private static func encodeFrame(_ opcode: Opcode, _ payload: Data) -> Data {
        var data = Data(capacity: 8 + payload.count)
        withUnsafeBytes(of: opcode.rawValue.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    /// Reads frames on a dedicated thread; the stream ends when the socket is shut down or dropped.
    private static func frames(from socket: IPCSocket) -> AsyncThrowingStream<Frame, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in socket.shutdown() }
            let reader = Thread {
                do {
                    while true {
                        let header = try socket.read(count: 8)
                        let opcode = header.uint32LittleEndian(at: 0)
                        let length = header.uint32LittleEndian(at: 4)
                        guard length <= Self.maxFrameSize else {
                            throw IPCSocket.SocketError.oversizedFrame(length)
                        }
                        let payload = try socket.read(count: Int(length))
                        continuation.yield(Frame(opcode: opcode, payload: payload))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            reader.name = "discord-ipc-reader"
            reader.start()
        }
    }

    private static func describeClose(_ payload: Data) -> String {
        let close = try? JSONDecoder().decode(ErrorPayload.self, from: payload)
        if close?.code == 4000 {
            return "Invalid client ID (4000): check clientId in ~/.config/cassette-discord-rpc/config.json"
        }
        let code = close?.code.map(String.init) ?? "?"
        return "\(close?.message ?? "no reason given") (code \(code))"
    }

    // MARK: - Socket discovery

    private static func socketCandidates() -> [String] {
        let rawDirectories: [String?] = [
            ProcessInfo.processInfo.environment["TMPDIR"],
            darwinUserTempDirectory(),
            NSTemporaryDirectory(),
            "/tmp"
        ]
        var directories: [String] = []
        for case let directory? in rawDirectories {
            let normalized = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
            if !normalized.isEmpty, !directories.contains(normalized) {
                directories.append(normalized)
            }
        }

        var paths: [String] = []
        for index in 0...9 {
            for directory in directories {
                let path = "\(directory)/discord-ipc-\(index)"
                if FileManager.default.fileExists(atPath: path) {
                    paths.append(path)
                }
            }
        }
        return paths
    }

    /// The per-user temp dir, which launchd agents don't always get through `$TMPDIR`.
    private static func darwinUserTempDirectory() -> String? {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Wire types

private struct Handshake: Encodable {
    let version: Int
    let clientId: String

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case clientId = "client_id"
    }
}

private struct SetActivityCommand: Encodable {
    struct Args: Encodable {
        let pid: Int32
        /// `nil` is omitted from the JSON, which is how Discord clears the presence.
        let activity: ActivityPayload?
    }

    let cmd = "SET_ACTIVITY"
    let args: Args
    let nonce: String
}

private struct ErrorPayload: Decodable {
    let code: Int?
    let message: String?
}

private struct IncomingMessage: Decodable {
    let cmd: String?
    let evt: String?
    let data: ErrorPayload?

    private enum CodingKeys: String, CodingKey {
        case cmd, evt, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cmd = try? container.decodeIfPresent(String.self, forKey: .cmd)
        evt = try? container.decodeIfPresent(String.self, forKey: .evt)
        // READY and command responses carry unrelated payloads here; only errors matter.
        data = try? container.decodeIfPresent(ErrorPayload.self, forKey: .data)
    }
}

private extension Data {
    func uint32LittleEndian(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for byte in 0..<4 {
            value |= UInt32(self[startIndex + offset + byte]) << (8 * UInt32(byte))
        }
        return value
    }
}
