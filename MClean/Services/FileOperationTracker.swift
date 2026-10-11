import Combine
import Foundation

/// Independent tools can outlive their views. Keep a lease for every mutation
/// until its worker finishes, so quit, relaunch and scheduled cleanup can wait.
final class FileOperationTracker: ObservableObject, @unchecked Sendable {
    static let shared = FileOperationTracker()
    let objectWillChange = ObservableObjectPublisher()
    private let lock = NSLock()
    private var operations: Set<UUID> = []

    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !operations.isEmpty
    }

    @discardableResult
    func begin() -> UUID {
        let token = UUID()
        lock.lock()
        operations.insert(token)
        lock.unlock()
        notifyObservers()
        return token
    }

    func end(_ token: UUID) {
        lock.lock()
        let removed = operations.remove(token) != nil
        lock.unlock()
        if removed { notifyObservers() }
    }

    private func notifyObservers() {
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }
}
