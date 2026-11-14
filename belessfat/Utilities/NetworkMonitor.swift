import Foundation
import Combine
import Network

@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isConnected = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "network.monitor")
    private var offlineTask: Task<Void, Never>?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            // Read the path on the monitor queue. It is not safe to touch later.
            let connected = path.status != .unsatisfied
            Task { @MainActor in
                self?.apply(connected)
            }
        }
        monitor.start(queue: queue)
    }

    /// Ignore brief unsatisfied updates. Those fire while a request starts even when the device is online.
    private func apply(_ connected: Bool) {
        offlineTask?.cancel()
        if connected {
            isConnected = true
            return
        }
        offlineTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            isConnected = false
        }
    }
}
