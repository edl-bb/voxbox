import Foundation

/// Runtime OS feature gates. Catalog, picker, and factory branches all
/// read `customCleanupModels` instead of a compile-time boolean.
nonisolated enum OSCapabilities {
    private static let lock = NSLock()
    /// Serializes tests that inject `testOverride` so XCTest classes
    /// running in parallel cannot clobber each other's expected catalog.
    private static let testGate = DispatchSemaphore(value: 1)
    nonisolated(unsafe) private static var _testOverride: Bool?

    /// Package-internal test hook. `nil` in production so the `#available`
    /// check is the only gate.
    static var testOverride: Bool? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _testOverride
        }
        set {
            lock.lock()
            _testOverride = newValue
            lock.unlock()
        }
    }

    /// True on macOS 27+, or whatever `testOverride` injects.
    static var customCleanupModels: Bool {
        if let testOverride { return testOverride }
        if #available(macOS 27, *) { return true }
        return false
    }

    /// Sets `testOverride` for the duration of `body`, restoring the
    /// previous value afterwards. Takes a test-only gate so parallel
    /// XCTest classes cannot interleave conflicting overrides. Does not
    /// hold `lock` across `body` (that would deadlock if `body` hops to
    /// the MainActor and reads `customCleanupModels`).
    static func withTestOverride<T>(_ value: Bool?, _ body: () throws -> T) rethrows -> T {
        testGate.wait()
        defer { testGate.signal() }
        let previous = testOverride
        testOverride = value
        defer { testOverride = previous }
        return try body()
    }
}
