import Foundation

@testable import PipecatToolbarCore

/// An in-memory `WantedServiceStore` shared by the driver and store tests. `wholeSetReads` counts
/// `read()` calls, so a test can assert that a caller never takes the whole set.
final class MemoryWantedStore: WantedServiceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var set: Set<Service>
    private var reads = 0
    init(_ initial: Set<Service> = []) { set = initial }
    var current: Set<Service> { lock.withLock { set } }
    var wholeSetReads: Int { lock.withLock { reads } }
    func read() -> Set<Service> { lock.withLock { reads += 1; return set } }
    func removeAll() { lock.withLock { set = [] } }
    func contains(_ service: Service) -> Bool { lock.withLock { set.contains(service) } }
    func setWanted(_ wanted: Bool, for service: Service) {
        lock.withLock { if wanted { set.insert(service) } else { set.remove(service) } }
    }
}
