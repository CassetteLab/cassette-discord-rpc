import Darwin
import Foundation

/// Minimal blocking client for a Unix domain socket.
///
/// Every call blocks, so reads run on a dedicated thread (see `DiscordIPCClient.frames(from:)`).
/// `@unchecked Sendable`: the descriptor never changes after init, `shutdown(2)` is safe to call
/// from any thread, and writes are serialised by the owning actor.
final class IPCSocket: @unchecked Sendable {

    enum SocketError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case syscall(String, Int32)
        case closedByPeer
        case oversizedFrame(UInt32)

        var description: String {
            switch self {
            case .pathTooLong(let path):
                "socket path too long: \(path)"
            case .syscall(let name, let code):
                "\(name) failed: \(String(cString: strerror(code)))"
            case .closedByPeer:
                "connection closed by Discord"
            case .oversizedFrame(let size):
                "refusing oversized frame (\(size) bytes)"
            }
        }
    }

    private let fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        Darwin.close(fd)
    }

    static func connect(path: String) throws -> IPCSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.syscall("socket", errno) }

        // A write to a Discord that just quit must surface as EPIPE, not kill the daemon.
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw SocketError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let result = withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketError.syscall("connect", code)
        }
        return IPCSocket(fd: fd)
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.syscall("write", errno)
                }
                offset += written
            }
        }
    }

    /// Reads exactly `count` bytes, or throws.
    func read(count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < count {
                let received = Darwin.read(fd, base + offset, count - offset)
                if received == 0 { throw SocketError.closedByPeer }
                if received < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.syscall("read", errno)
                }
                offset += received
            }
        }
        return data
    }

    /// Wakes up a `read` blocked on another thread. The descriptor itself is closed in `deinit`.
    func shutdown() {
        Darwin.shutdown(fd, SHUT_RDWR)
    }
}
