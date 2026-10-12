import Foundation

// A write to a socket whose peer just went away must never kill the daemon.
signal(SIGPIPE, SIG_IGN)

do {
    let config = try loadConfiguration()
    let daemon = Daemon(config: config)
    await daemon.run()
} catch {
    exitWithFatalError("Startup failed: \(error.localizedDescription)")
}
