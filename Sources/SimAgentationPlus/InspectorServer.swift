#if DEBUG
import Foundation
import Network
import os

/// A tiny HTTP server on 127.0.0.1. The simulator shares the Mac's
/// loopback, so sim-agentation on the host can reach it directly.
///
///     GET /snapshot  →  views, layers and tags as JSON
final class InspectorServer: @unchecked Sendable {
    static let shared = InspectorServer()

    private let queue = DispatchQueue(label: "SimAgentationPlus.server")
    private let log = Logger(subsystem: "SimAgentationPlus", category: "server")
    private var listener: NWListener? // only touched on the main actor

    @MainActor
    func start(port: UInt16) {
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        params.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [log] state in
                if case .failed(let error) = state { log.error("listener failed: \(error)") }
            }
            listener.start(queue: queue)
            self.listener = listener
            log.info("listening on 127.0.0.1:\(port)")
        } catch {
            log.error("could not start on port \(port): \(error)")
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil || buffer.count > 64 * 1024 { connection.cancel() } else { self.read(connection, buffer: buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            Task { @MainActor in
                let (status, body) = Self.respond(to: path)
                self.write(connection, status: status, body: body)
            }
        }
    }

    @MainActor
    private static func respond(to path: String) -> (String, Data) {
        switch path.split(separator: "?").first {
        case "/snapshot":
            let encoder = JSONEncoder()
            do {
                return ("200 OK", try encoder.encode(SnapshotBuilder.build()))
            } catch {
                return ("500 Internal Server Error", Data("{\"error\":\"\(error)\"}".utf8))
            }
        default:
            return ("404 Not Found", Data("{\"error\":\"not found\"}".utf8))
        }
    }

    private func write(_ connection: NWConnection, status: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif
