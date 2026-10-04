import CryptoKit
import Foundation

/// A small HTTP/1.1 server with WebSocket upgrade. Loopback only. One request per connection (`Connection: close`), which
/// keeps parsing simple and costs nothing on localhost.
final class HTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        /// The path as a browser's URL parser leaves it: dot segments
        /// resolved, backslashes as slashes, still percent-encoded.
        let path: String
        /// Query parameters in order, decoded like URLSearchParams.
        let query: [(name: String, value: String)]
        let headers: [String: String] // lowercased names
        let body: Data

        func header(_ name: String) -> String? { headers[name.lowercased()] }

        /// URLSearchParams.get: the first value.
        func queryValue(_ name: String) -> String? { query.first { $0.name == name }?.value }
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data

        static func text(_ text: String, status: Int) -> Response {
            Response(status: status, headers: ["Content-Type": "text/plain;charset=utf-8"], body: Data(text.utf8))
        }
    }

    enum Outcome: Sendable {
        case respond(Response)
        /// Hand the connection to a WebSocket session after the handshake.
        case upgrade(@Sendable (WebSocket) -> Void)
    }

    typealias Handler = @Sendable (Request) async -> Outcome

    private let port: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "sim-agentation.http")
    private var listener: Listener?

    init(port: UInt16, handler: @escaping Handler) throws {
        self.port = port
        self.handler = handler
    }

    func start() async throws {
        listener = try Listener(port: port, queue: queue) { [weak self] connection in
            self?.readRequest(connection, buffer: Data(), sentContinue: false)
        }
    }

    private func readRequest(_ connection: Connection, buffer: Data, sentContinue: Bool) {
        connection.receive(maximumLength: 1 << 20) { [weak self] data, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            var sentContinue = sentContinue
            switch Self.parse(buffer) {
            case .complete(let request):
                // Each request runs in its own task, so a long poll never holds up the others.
                Task { await self.handle(request, on: connection) }
                return
            case .awaitingBody(let expectsContinue):
                if expectsContinue && !sentContinue {
                    sentContinue = true
                    connection.send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
                }
            case .incomplete:
                break
            }
            if done || error != nil || buffer.count > 128 << 20 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer, sentContinue: sentContinue)
            }
        }
    }

    private enum Parsed {
        case incomplete
        case awaitingBody(expectsContinue: Bool)
        case complete(Request)
    }

    /// Returns a request once the headers and the whole body have arrived.
    private static func parse(_ buffer: Data) -> Parsed {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .incomplete }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard buffer.count - bodyStart >= length else {
            return .awaitingBody(expectsContinue: headers["expect"]?.lowercased() == "100-continue")
        }
        let (path, query) = splitTarget(String(requestLine[1]))
        return .complete(Request(
            method: String(requestLine[0]),
            path: path,
            query: query,
            headers: headers,
            body: buffer.subdata(in: bodyStart..<(bodyStart + length))
        ))
    }

    // MARK: - URL parsing, as `new URL(req.url)` does it

    static func splitTarget(_ target: String) -> (path: String, query: [(name: String, value: String)]) {
        var rest = Substring(target)
        // Absolute-form targets ("http://host/path") carry the path after the authority.
        if let scheme = rest.range(of: "://"), rest[..<scheme.lowerBound].allSatisfy({ $0.isLetter }) {
            let afterAuthority = rest[scheme.upperBound...]
            rest = afterAuthority.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }).map { afterAuthority[$0...] } ?? ""
        }
        if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }
        var queryString = ""
        if let question = rest.firstIndex(of: "?") {
            queryString = String(rest[rest.index(after: question)...])
            rest = rest[..<question]
        }
        return (normalizePath(String(rest)), parseQuery(queryString))
    }

    /// WHATWG URL path parsing: "\\" is "/", "." and ".." segments (also
    /// percent-encoded) are resolved, and characters outside the path set
    /// are percent-encoded.
    static func normalizePath(_ raw: String) -> String {
        var parts = raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.first == "" { parts.removeFirst() }
        var segments: [String] = []
        for (i, segment) in parts.enumerated() {
            let last = i == parts.count - 1
            switch segment.lowercased() {
            case "..", ".%2e", "%2e.", "%2e%2e":
                if !segments.isEmpty { segments.removeLast() }
                if last { segments.append("") }
            case ".", "%2e":
                if last { segments.append("") }
            default:
                segments.append(percentEncodePathSegment(segment))
            }
        }
        return "/" + segments.joined(separator: "/")
    }

    private static func percentEncodePathSegment(_ segment: String) -> String {
        var out = ""
        for byte in segment.utf8 {
            switch byte {
            case 0..<0x21, 0x22, 0x23, 0x3C, 0x3E, 0x3F, 0x60, 0x7B, 0x7D, 0x7F...:
                out += String(format: "%%%02X", byte)
            default:
                out.unicodeScalars.append(Unicode.Scalar(byte))
            }
        }
        return out
    }

    /// application/x-www-form-urlencoded parsing, as URLSearchParams does it.
    static func parseQuery(_ query: String) -> [(name: String, value: String)] {
        query.split(separator: "&").map { pair in
            if let equals = pair.firstIndex(of: "=") {
                return (formDecode(pair[..<equals]), formDecode(pair[pair.index(after: equals)...]))
            }
            return (formDecode(pair), "")
        }
    }

    private static func formDecode(_ s: Substring) -> String {
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == UInt8(ascii: "+") {
                out.append(0x20)
            } else if byte == UInt8(ascii: "%"), i + 2 < bytes.count,
                      let hi = JS.asciiHexValue(bytes[i + 1]), let lo = JS.asciiHexValue(bytes[i + 2]) {
                out.append(UInt8(hi << 4 | lo))
                i += 2
            } else {
                out.append(byte)
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - responses

    private func handle(_ request: Request, on connection: Connection) async {
        switch await handler(request) {
        case .respond(let response):
            send(response, on: connection, headOnly: request.method == "HEAD")
        case .upgrade(let session):
            guard request.header("upgrade")?.lowercased() == "websocket", let key = request.header("sec-websocket-key") else {
                send(.text("upgrade failed", status: 400), on: connection, headOnly: false)
                return
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            connection.send(Data(head.utf8))
            session(WebSocket(connection: connection, queue: queue))
        }
    }

    /// HEAD gets the headers only.
    private func send(_ response: Response, on connection: Connection, headOnly: Bool) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        var headers = response.headers
        if response.status != 204 && response.status != 304 { headers["Content-Length"] = String(response.body.count) }
        headers["Connection"] = "close"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        let body = headOnly || response.status == 204 ? Data() : response.body
        connection.send(Data(head.utf8) + body) { _ in connection.cancel() }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 500: "Internal Server Error"
        default: status < 500 ? "Error" : "Internal Server Error"
        }
    }
}

/// RFC 6455 frames over an upgraded connection: text and binary messages,
/// ping/pong and close. Client frames are masked; ours are not.
final class WebSocket: @unchecked Sendable {
    enum Message: Sendable { case text(String), binary(Data) }

    private let connection: Connection
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
    private var pendingBytes = 0

    init(connection: Connection, queue: DispatchQueue) {
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

    /// Bytes sent that the viewer hasn't received yet, as far as this end
    /// can tell: still queued here, or in the kernel awaiting acknowledgement.
    var queuedBytes: Int {
        writesLock.lock(); let pending = pendingBytes; writesLock.unlock()
        return pending + connection.kernelQueued
    }

    private func adjustPending(_ delta: Int, bytes: Int) {
        writesLock.lock(); pendingWrites += delta; pendingBytes += delta * bytes; writesLock.unlock()
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
            self.adjustPending(1, bytes: bytes.count)
            self.connection.send(bytes) { [weak self] error in
                self?.adjustPending(-1, bytes: bytes.count)
                if error != nil { self?.finish(sendClose: false) }
            }
        }
    }

    private func receive() {
        connection.receive(maximumLength: 1 << 20) { [weak self] data, done, error in
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
            connection.send(Data([0x88, 0x00])) { [connection] _ in connection.cancel() }
        } else {
            connection.cancel()
        }
        let callback = onClose
        onMessage = nil
        onClose = nil
        callback?()
    }
}
