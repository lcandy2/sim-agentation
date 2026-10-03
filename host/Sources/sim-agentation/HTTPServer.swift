import CryptoKit
import Foundation
import Network

/// A small HTTP/1.1 server with WebSocket upgrade, on Network.framework.
/// Loopback only. One request per connection (`Connection: close`), which
/// keeps parsing simple and costs nothing on localhost.
final class HTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String] // lowercased names
        let body: Data

        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data

        static func json(_ object: Any, status: Int = 200) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data("null".utf8)
            return Response(status: status, headers: ["Content-Type": "application/json"], body: data)
        }

        static func text(_ text: String, status: Int) -> Response {
            Response(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
        }
    }

    enum Outcome: Sendable {
        case respond(Response)
        /// Hand the connection to a WebSocket session after the handshake.
        case upgrade(@Sendable (WebSocket) -> Void)
    }

    typealias Handler = @Sendable (Request) async -> Outcome

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "sim-agentation.http")

    init(port: UInt16, handler: @escaping Handler) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
        self.handler = handler
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if resumed.claim() { continuation.resume() }
                case .failed(let error): if resumed.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                Task { await self.handle(request, on: connection) }
            } else if done || error != nil || buffer.count > 64 << 20 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer)
            }
        }
    }

    /// Returns a request once the headers and the whole body have arrived.
    private static func parse(_ buffer: Data) -> Request? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard buffer.count - bodyStart >= length else { return nil }
        let target = String(requestLine[1])
        let components = URLComponents(string: "http://localhost\(target)")
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(
            method: String(requestLine[0]),
            path: components?.percentEncodedPath ?? target,
            query: query,
            headers: headers,
            body: buffer.subdata(in: bodyStart..<(bodyStart + length))
        )
    }

    private func handle(_ request: Request, on connection: NWConnection) async {
        switch await handler(request) {
        case .respond(let response):
            send(response, on: connection)
        case .upgrade(let session):
            guard request.header("upgrade")?.lowercased() == "websocket", let key = request.header("sec-websocket-key") else {
                send(.text("expected a WebSocket upgrade", status: 400), on: connection)
                return
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            session(WebSocket(connection: connection, queue: queue))
        }
    }

    private func send(_ response: Response, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 415: "Unsupported Media Type"
        default: status < 500 ? "Error" : "Internal Server Error"
        }
    }
}

/// Resumes a continuation at most once.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// RFC 6455 frames over an upgraded connection: text and binary messages,
/// ping/pong and close. Client frames are masked; ours are not.
final class WebSocket: @unchecked Sendable {
    enum Message: Sendable { case text(String), binary(Data) }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var fragments = Data()
    private var fragmentOpcode: UInt8 = 0
    private var onMessage: (@Sendable (Message) -> Void)?
    private var onClose: (@Sendable () -> Void)?
    private var closed = false

    /// Frames still being written. Video frames are skipped while the socket
    /// is behind, so a slow viewer gets fewer frames rather than old ones.
    private let writesLock = NSLock()
    private var pendingWrites = 0

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start(onMessage: @escaping @Sendable (Message) -> Void, onClose: @escaping @Sendable () -> Void) {
        self.onMessage = onMessage
        self.onClose = onClose
        receive()
    }

    func send(text: String) { send(opcode: 0x1, payload: Data(text.utf8)) }

    func send(binary: Data) { send(opcode: 0x2, payload: binary) }

    func send(json: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        send(opcode: 0x1, payload: data)
    }

    var isBackedUp: Bool {
        writesLock.lock(); defer { writesLock.unlock() }
        return pendingWrites > 1
    }

    private func adjustPending(_ delta: Int) {
        writesLock.lock(); pendingWrites += delta; writesLock.unlock()
    }

    func close() {
        queue.async { self.finish(sendClose: true) }
    }

    private func send(opcode: UInt8, payload: Data) {
        var frame = Data([0x80 | opcode])
        switch payload.count {
        case ..<126: frame.append(UInt8(payload.count))
        case ..<65536:
            frame.append(126)
            frame.append(contentsOf: withUnsafeBytes(of: UInt16(payload.count).bigEndian, Array.init))
        default:
            frame.append(127)
            frame.append(contentsOf: withUnsafeBytes(of: UInt64(payload.count).bigEndian, Array.init))
        }
        frame.append(payload)
        let bytes = frame
        queue.async {
            guard !self.closed else { return }
            self.adjustPending(1)
            self.connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                self?.adjustPending(-1)
                if error != nil { self?.finish(sendClose: false) }
            })
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            while let (opcode, fin, payload) = self.nextFrame() { self.handle(opcode: opcode, fin: fin, payload: payload) }
            if done || error != nil { self.finish(sendClose: false) } else if !self.closed { self.receive() }
        }
    }

    private func nextFrame() -> (UInt8, Bool, Data)? {
        let bytes = [UInt8](buffer.prefix(14))
        guard bytes.count >= 2 else { return nil }
        let fin = bytes[0] & 0x80 != 0
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }
            offset = 10
        }
        let maskLength = masked ? 4 : 0
        guard buffer.count >= offset + maskLength + length else { return nil }
        let start = buffer.startIndex
        let mask = masked ? [UInt8](buffer[(start + offset)..<(start + offset + 4)]) : []
        var payload = [UInt8](buffer[(start + offset + maskLength)..<(start + offset + maskLength + length)])
        if masked { for i in payload.indices { payload[i] ^= mask[i % 4] } }
        buffer.removeFirst(offset + maskLength + length)
        return (opcode, fin, Data(payload))
    }

    private func handle(opcode: UInt8, fin: Bool, payload: Data) {
        switch opcode {
        case 0x0: // continuation
            fragments.append(payload)
            if fin { deliver(opcode: fragmentOpcode, payload: fragments); fragments = Data() }
        case 0x1, 0x2:
            if fin { deliver(opcode: opcode, payload: payload) } else { fragmentOpcode = opcode; fragments = payload }
        case 0x8: finish(sendClose: true)
        case 0x9: send(opcode: 0xA, payload: payload) // ping → pong
        default: break
        }
    }

    private func deliver(opcode: UInt8, payload: Data) {
        onMessage?(opcode == 0x1 ? .text(String(decoding: payload, as: UTF8.self)) : .binary(payload))
    }

    private func finish(sendClose: Bool) {
        guard !closed else { return }
        closed = true
        if sendClose {
            connection.send(content: Data([0x88, 0x00]), completion: .contentProcessed { [connection] _ in connection.cancel() })
        } else {
            connection.cancel()
        }
        let callback = onClose
        onMessage = nil
        onClose = nil
        callback?()
    }
}
