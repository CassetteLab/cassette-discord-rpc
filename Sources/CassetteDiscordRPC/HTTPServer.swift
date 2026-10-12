import Foundation
import Network
import os

private let logger = Logger(
    subsystem: "fr.mathieu-dubart.cassette-discord-rpc",
    category: "HTTPServer"
)

enum NowPlayingEvent: Sendable {
    case trackChanged(NowPlayingInfo)
    case playbackStopped
}

enum HTTPServerError: Error, CustomStringConvertible {
    case invalidPort(UInt16)

    var description: String {
        switch self {
        case .invalidPort(let port): "invalid port number \(port)"
        }
    }
}

/// Minimal HTTP/1.1 endpoint that Cassette posts to.
///
/// - `POST /now-playing` — JSON `NowPlayingInfo`
/// - `POST /playback-stopped`
/// - `GET /health` — JSON status of the Discord connection, for troubleshooting
actor HTTPServer {

    private static let maxRequestSize = 64 * 1024

    private let port: UInt16
    private let statusProvider: @Sendable () async -> DiscordStatus
    private var eventContinuation: AsyncStream<NowPlayingEvent>.Continuation?
    private var listener: NWListener?

    init(port: UInt16, statusProvider: @escaping @Sendable () async -> DiscordStatus) {
        self.port = port
        self.statusProvider = statusProvider
    }

    /// Starts listening and returns only once the port is actually bound, so a busy port fails loudly.
    func start() async throws -> AsyncStream<NowPlayingEvent> {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw HTTPServerError.invalidPort(port)
        }

        let listener = try NWListener(using: .tcp, on: nwPort)
        self.listener = listener

        let (stream, continuation) = AsyncStream.makeStream(of: NowPlayingEvent.self)
        eventContinuation = continuation

        listener.newConnectionHandler = { [self] connection in
            Task { await self.handleConnection(connection) }
        }

        let port = self.port
        do {
            try await withCheckedThrowingContinuation { (startup: CheckedContinuation<Void, Error>) in
                let startupHandled = OSAllocatedUnfairLock(initialState: false)
                let claimStartup: @Sendable () -> Bool = {
                    startupHandled.withLock { handled in
                        if handled { return false }
                        handled = true
                        return true
                    }
                }

                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if claimStartup() {
                            logger.info("HTTP server listening on port \(port, privacy: .public)")
                            startup.resume()
                        }
                    case .failed(let error), .waiting(let error):
                        if claimStartup() {
                            startup.resume(throwing: error)
                        } else {
                            // Better to exit and let launchd restart us than to stay alive but deaf.
                            exitWithFatalError("HTTP listener on port \(port) stopped: \(error)")
                        }
                    default:
                        break
                    }
                }
                listener.start(queue: .global(qos: .userInitiated))
            }
        } catch {
            listener.cancel()
            self.listener = nil
            continuation.finish()
            throw error
        }

        return stream
    }

    // MARK: - Request handling

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .userInitiated))

        guard let request = await receiveRequest(from: connection) else {
            await respond(400, on: connection)
            return
        }

        switch (request.method, request.path) {
        case ("POST", "/now-playing"):
            do {
                let info = try JSONDecoder().decode(NowPlayingInfo.self, from: request.body)
                eventContinuation?.yield(.trackChanged(info))
                await respond(200, on: connection)
            } catch {
                logger.warning("Invalid /now-playing body: \(String(describing: error), privacy: .public)")
                await respond(400, on: connection)
            }

        case ("POST", "/playback-stopped"):
            eventContinuation?.yield(.playbackStopped)
            await respond(200, on: connection)

        case ("GET", "/health"):
            let status = await statusProvider()
            let body = (try? JSONEncoder().encode(status)) ?? Data()
            await respond(200, body: body, on: connection)

        default:
            logger.warning("Unknown endpoint: \(request.method, privacy: .public) \(request.path, privacy: .public)")
            await respond(404, on: connection)
        }
    }

    private struct Request {
        let method: String
        let path: String
        let body: Data
    }

    private func receiveRequest(from connection: NWConnection) async -> Request? {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)

        while buffer.range(of: separator) == nil {
            guard buffer.count < Self.maxRequestSize,
                  let chunk = await receiveChunk(from: connection), !chunk.isEmpty else {
                return nil
            }
            buffer.append(chunk)
        }

        guard let separatorRange = buffer.range(of: separator),
              let headerText = String(data: buffer[buffer.startIndex..<separatorRange.lowerBound], encoding: .utf8)
        else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0])
        // Ignore any query string.
        let path = String(requestLine[1].split(separator: "?", maxSplits: 1).first ?? "")

        var contentLength = 0
        for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
            contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        guard contentLength >= 0, contentLength <= Self.maxRequestSize else { return nil }

        var body = Data(buffer[separatorRange.upperBound...])
        while body.count < contentLength {
            guard let chunk = await receiveChunk(from: connection), !chunk.isEmpty else { return nil }
            body.append(chunk)
        }

        return Request(method: method, path: path, body: body.prefix(contentLength))
    }

    private func receiveChunk(from connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                continuation.resume(returning: error == nil ? (data ?? Data()) : nil)
            }
        }
    }

    private func respond(_ statusCode: Int, body: Data = Data(), on connection: NWConnection) async {
        let reason = switch statusCode {
        case 200: "OK"
        case 404: "Not Found"
        default: "Bad Request"
        }
        var response = Data("HTTP/1.1 \(statusCode) \(reason)\r\n".utf8)
        if !body.isEmpty {
            response.append(Data("Content-Type: application/json\r\n".utf8))
        }
        response.append(Data("Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8))
        response.append(body)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
                continuation.resume()
            })
        }
    }
}
