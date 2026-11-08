import Foundation

/// Minimal mutex-protected box for state shared between the ARKit delegate
/// queue, the CoreMotion queue, the audio control queue and the main thread.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    @discardableResult
    func mutate<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    func set(_ newValue: Value) {
        mutate { $0 = newValue }
    }
}
