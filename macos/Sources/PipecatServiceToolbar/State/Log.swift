import os

/// Unified logging: `log stream --predicate 'subsystem == "ai.pipecat.ServiceToolbar"'`.
enum Log {
    static let app = Logger(subsystem: "ai.pipecat.ServiceToolbar", category: "app")
    static let install = Logger(subsystem: "ai.pipecat.ServiceToolbar", category: "install")
    static let server = Logger(subsystem: "ai.pipecat.ServiceToolbar", category: "server")
}
