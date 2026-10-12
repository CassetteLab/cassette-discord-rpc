import Foundation
import os

private let logger = Logger(
    subsystem: "fr.mathieu-dubart.cassette-discord-rpc",
    category: "Main"
)

/// Logs a fatal error and exits.
///
/// Also written to stderr: os.Logger output never reaches the terminal or the launch agent's
/// `.err` file, and a daemon that dies silently is exactly what makes setup impossible to debug.
func exitWithFatalError(_ message: String) -> Never {
    logger.fault("\(message, privacy: .public)")
    FileHandle.standardError.write(Data("cassette-discord-rpc: \(message)\n".utf8))
    exit(EXIT_FAILURE)
}
