import Foundation
import Logging

/// Shared `swift-log` `Logger` for everything inside `HeidrunServerKit`.
/// The executable's `main.swift` is responsible for calling
/// `LoggingSystem.bootstrap(...)` once at startup; until that runs the
/// default backend writes to stderr.
///
/// Library callers can read this directly (it's `@MainActor`-safe — `Logger`
/// itself is `Sendable`) and inherit the bootstrapped handler.
public let serverLogger = Logger(label: "org.tastybytes.heidrun.server")
