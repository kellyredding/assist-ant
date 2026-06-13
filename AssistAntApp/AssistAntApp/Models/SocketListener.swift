import Foundation
import Network

/// Listens for event envelopes on a Unix domain socket using
/// Network.framework.
///
/// Adapted from
/// ~/projects/kellyredding/galaxy/GalaxyApp/GalaxyApp/Models/SocketListener.swift.
/// AssistAnt strips the Galaxy-specific reassembly logging (no
/// 25KB+ turn envelopes here) but preserves the per-connection
/// buffering, flock-based single-instance lock, and stale-socket
/// cleanup.
final class SocketListener {
    private let socketPath: String
    private let lockPath: String
    private var listener: NWListener?
    private let queue = DispatchQueue(
        label: "com.kellyredding.AssistAnt.socket-listener"
    )

    /// fd for the lock file — kept open for process lifetime to
    /// hold flock.
    private var lockFileDescriptor: Int32 = -1

    /// Callback invoked on the main queue for each decoded
    /// envelope.
    var onEnvelope: ((EventEnvelope) -> Void)?

    /// Callback for request envelopes that expect a reply. Invoked on the
    /// listener queue (so a quick store read can answer inline before the
    /// connection closes); returns the reply bytes — one JSON line, no trailing
    /// newline; this adds the terminator — or nil to fall through to the
    /// fire-and-forget `onEnvelope` path.
    var onRequest: ((EventEnvelope) -> Data?)?

    private var activeConnections: [NWConnection] = []

    /// Per-connection accumulator for partial JSON lines. Bytes
    /// accumulate until a newline arrives. Keyed by
    /// ObjectIdentifier(connection). All mutations happen on
    /// `queue` (serial), so no extra synchronization needed.
    private var connectionBuffers: [ObjectIdentifier: Data] = [:]

    /// Safety cap on per-connection buffer growth. The publisher
    /// always terminates with `\n`, so this much without one
    /// indicates a misbehaving sender — drop rather than grow.
    private static let maxBufferBytes: Int = 10 * 1024 * 1024

    init(socketPath: String, lockPath: String) {
        self.socketPath = socketPath
        self.lockPath = lockPath
    }

    deinit { stop() }

    // MARK: - Lifecycle

    /// Start listening. Acquires the flock on the .lock file,
    /// removes any stale socket file, binds NWListener.
    /// Returns false if another instance owns the lock.
    @discardableResult
    func start() -> Bool {
        guard acquireLock() else {
            NSLog("SocketListener: lock acquisition failed — another instance owns the socket")
            return false
        }

        removeStaleSocket()

        let endpoint = NWEndpoint.unix(path: socketPath)
        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = endpoint

        do {
            listener = try NWListener(using: params)
        } catch {
            NSLog("SocketListener: failed to create NWListener: \(error.localizedDescription)")
            releaseLock()
            return false
        }

        listener?.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                NSLog("SocketListener: entered failed state: \(error.localizedDescription)")
                self?.restartAfterFailure()
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: queue)
        NSLog("SocketListener: listening on \(socketPath)")
        return true
    }

    func stop() {
        for connection in activeConnections {
            connection.cancel()
        }
        activeConnections.removeAll()

        listener?.cancel()
        listener = nil

        try? FileManager.default.removeItem(atPath: socketPath)

        releaseLock()
    }

    // MARK: - Lock file

    private func acquireLock() -> Bool {
        let parentDir = (lockPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: parentDir, withIntermediateDirectories: true
        )

        lockFileDescriptor = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard lockFileDescriptor >= 0 else { return false }

        let result = flock(lockFileDescriptor, LOCK_EX | LOCK_NB)
        if result != 0 {
            close(lockFileDescriptor)
            lockFileDescriptor = -1
            return false
        }
        return true
    }

    private func releaseLock() {
        guard lockFileDescriptor >= 0 else { return }
        flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
        try? FileManager.default.removeItem(atPath: lockPath)
    }

    private func removeStaleSocket() {
        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    // MARK: - Connection handling

    private func handleNewConnection(_ connection: NWConnection) {
        activeConnections.append(connection)
        let key = ObjectIdentifier(connection)
        connectionBuffers[key] = Data()

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .cancelled = state {
                if let conn = connection { self?.removeConnection(conn) }
            } else if case .failed = state {
                if let conn = connection { self?.removeConnection(conn) }
                connection?.cancel()
            }
        }

        connection.start(queue: queue)
        receiveData(on: connection)
    }

    private func removeConnection(_ connection: NWConnection) {
        activeConnections.removeAll { $0 === connection }
        let key = ObjectIdentifier(connection)
        if let buffer = connectionBuffers[key], !buffer.isEmpty {
            let preview = String(data: buffer.prefix(200), encoding: .utf8) ?? "<binary>"
            NSLog("SocketListener: connection closed with \(buffer.count)B unconsumed — preview: \(preview)")
        }
        connectionBuffers.removeValue(forKey: key)
    }

    private func receiveData(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65536
        ) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.processReceivedData(data, on: connection)
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self?.receiveData(on: connection)
            }
        }
    }

    private func processReceivedData(_ data: Data, on connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        var buffer = connectionBuffers[key] ?? Data()
        buffer.append(data)

        if buffer.count > Self.maxBufferBytes {
            NSLog("SocketListener: buffer for connection exceeded \(Self.maxBufferBytes)B without newline — dropping (\(buffer.count)B accumulated)")
            connectionBuffers[key] = Data()
            return
        }

        let newline: UInt8 = 0x0A
        var cursor = buffer.startIndex

        while let nlIdx = buffer[cursor...].firstIndex(of: newline) {
            let lineRange = cursor..<nlIdx
            cursor = buffer.index(after: nlIdx)

            let lineData = buffer[lineRange]
            let trimmed = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty,
                  let jsonData = trimmed.data(using: .utf8)
            else { continue }

            do {
                let envelope = try JSONDecoder().decode(EventEnvelope.self, from: jsonData)
                // A request event gets a reply on this same connection; anything
                // else stays fire-and-forget, dispatched on the main queue.
                if let reply = onRequest?(envelope) {
                    sendReply(reply, on: connection)
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.onEnvelope?(envelope)
                    }
                }
            } catch {
                NSLog("SocketListener: failed to decode envelope (\(jsonData.count)B): \(error.localizedDescription) — preview: \(String(trimmed.prefix(200)))")
            }
        }

        if cursor < buffer.endIndex {
            connectionBuffers[key] = Data(buffer[cursor...])
        } else {
            connectionBuffers[key] = Data()
        }
    }

    /// Write a reply line back on the originating connection — newline-framed so
    /// the CLI's line reader sees a complete record — then let the connection
    /// close on the client's teardown.
    private func sendReply(_ data: Data, on connection: NWConnection) {
        var framed = data
        framed.append(0x0A)
        connection.send(content: framed, completion: .contentProcessed { _ in })
    }

    // MARK: - Error recovery

    private func restartAfterFailure() {
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.removeStaleSocket()
            _ = self.start()
        }
    }
}
