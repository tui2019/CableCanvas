import Foundation
import Network

protocol FrameTransportServer: AnyObject {
    var hasClient: Bool { get }
    var onClientConnectionChanged: (@Sendable (Bool) -> Void)? { get set }
    func start(host: String, port: UInt16) throws
    func send(_ packet: Data)
    func stop()
}

final class TcpFrameTransportServer: FrameTransportServer, @unchecked Sendable {
    var onClientConnectionChanged: (@Sendable (Bool) -> Void)?

    private let queue = DispatchQueue(label: "com.cablecanvas.transport")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var handshakeComplete = false

    var hasClient: Bool {
        queue.sync { connection != nil && handshakeComplete }
    }

    func start(host: String, port: UInt16) throws {
        let nwPort = NWEndpoint.Port(rawValue: port)
        guard let nwPort else {
            throw NSError(
                domain: "CableCanvas.Transport",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Invalid TCP port: \(port)"]
            )
        }

        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] newConnection in
            self?.attachConnection(newConnection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func send(_ packet: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let connection = self.connection, self.handshakeComplete else { return }
            connection.send(content: packet, completion: .contentProcessed { sendError in
                _ = sendError
            })
        }
    }

    func stop() {
        queue.sync {
            handshakeComplete = false
            connection?.cancel()
            connection = nil
            listener?.cancel()
            listener = nil
        }
        onClientConnectionChanged?(false)
    }

    private func attachConnection(_ newConnection: NWConnection) {
        if let existing = connection { existing.cancel() }
        connection = newConnection
        handshakeComplete = false

        newConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.performClientHandshake(on: newConnection)
            case .failed:
                self.clearConnection(ifMatches: newConnection)
            case .cancelled:
                self.clearConnection(ifMatches: newConnection)
            default:
                break
            }
        }

        newConnection.start(queue: queue)
    }

    private func performClientHandshake(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil {
                self.clearConnection(ifMatches: connection)
                return
            }
            let ascii = data.flatMap { String(data: $0, encoding: .ascii) }
            guard let data, data.count == 4, ascii == "CCH1" else {
                self.clearConnection(ifMatches: connection)
                return
            }
            self.handshakeComplete = true
            self.onClientConnectionChanged?(true)
        }
    }
    private func clearConnection(ifMatches target: NWConnection) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.connection === target else { return }
            self.handshakeComplete = false
            self.connection?.cancel()
            self.connection = nil
            self.onClientConnectionChanged?(false)
        }
    }
}
