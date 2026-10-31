import Foundation

@testable import PipecatToolbarCore

/// An in-memory `LastUsedStore` shared by the driver and store tests. `writes` records every
/// `setLastUsed` call in order, so a test can assert a start recorded once (or not at all).
final class MemoryLastUsedStore: LastUsedStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ServiceKind: Service]
    private var log: [Service] = []
    init(_ initial: [ServiceKind: Service] = [:]) { values = initial }
    var snapshot: [ServiceKind: Service] { lock.withLock { values } }
    var writes: [Service] { lock.withLock { log } }
    func lastUsed(_ kind: ServiceKind) -> Service? { lock.withLock { values[kind] } }
    func setLastUsed(_ service: Service) {
        lock.withLock {
            values[service.kind] = service
            log.append(service)
        }
    }
    func removeAll() { lock.withLock { values = [:] } }
}
