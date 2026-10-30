import Foundation

/// Meldet Änderungen an Datenbank und Einstellungen. Ersatz für die Room-Flows der Android-App:
/// Ansichten lauschen auf `stream()` und lesen ihren Zustand danach neu. Bewusst grob (eine
/// Meldung für alles), weil das Neulesen nur Millisekunden dauert.
public final class DataChanges: @unchecked Sendable {

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init() {}

    public func stream() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        lock.lock()
        continuations[id] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.continuations[id] = nil
            self.lock.unlock()
        }
        return stream
    }

    public func notify() {
        lock.lock()
        let current = Array(continuations.values)
        lock.unlock()
        for continuation in current { continuation.yield() }
    }
}
