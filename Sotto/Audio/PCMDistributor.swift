import Foundation

/// Fan-out point for normalized, pre-mix PCM. Subscribers run synchronously on the
/// publisher's capture queue so that buffers are never accumulated by this type.
final class PCMDistributor: @unchecked Sendable {
    typealias Handler = @Sendable (CapturedAudioChunk) -> Void

    private struct Subscription {
        let source: AudioSource?
        let handler: Handler
    }

    private let lock = NSLock()
    private var subscriptions: [UUID: Subscription] = [:]

    @discardableResult
    func subscribe(to source: AudioSource? = nil, handler: @escaping Handler) -> UUID {
        let identifier = UUID()
        lock.withLock {
            subscriptions[identifier] = Subscription(source: source, handler: handler)
        }
        return identifier
    }

    func unsubscribe(_ identifier: UUID) {
        _ = lock.withLock {
            subscriptions.removeValue(forKey: identifier)
        }
    }

    func publish(_ chunk: CapturedAudioChunk) {
        let handlers: [Handler] = lock.withLock {
            subscriptions.values.compactMap { subscription in
                guard subscription.source == nil || subscription.source == chunk.source else {
                    return nil
                }
                return subscription.handler
            }
        }
        handlers.forEach { $0(chunk) }
    }
}
