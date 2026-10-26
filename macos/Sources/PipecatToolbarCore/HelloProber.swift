import Foundation

/// Probes one loopback catalog port for a `server.hello`. `ExternalProbe` is the real one;
/// tests inject outcomes through this (the discovery pass is written against it).
public protocol HelloProber: Sendable {
    /// Never throws. A cancelled caller gets an outcome it must discard.
    func probe(port: Int) async -> ExternalProbe.Outcome
}

extension ExternalProbe: HelloProber {}
