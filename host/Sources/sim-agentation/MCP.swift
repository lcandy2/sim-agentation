import Foundation

/// Minimal MCP stdio server. Every tool is a thin
/// call into the HTTP API, so the browser UI and the agent always see the
/// same store. Nothing but JSON-RPC goes to stdout.
final class MCPServer: @unchecked Sendable {
    let port: UInt16
    let api: String
    private let session: URLSession
    private let probeSession: URLSession
    private let outputLock = NSLock()

    // Newest first. This server only uses tools, which work the same in all of them.
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    init(port: UInt16) {
        self.port = port
        api = "http://127.0.0.1:\(port)"
        func makeSession(timeout: TimeInterval) -> URLSession {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:] // loopback; never through a system proxy
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            return URLSession(configuration: config)
        }
        session = makeSession(timeout: 600) // sim_watch long-polls for up to 110 s
        probeSession = makeSession(timeout: 0.8)
    }

    // MARK: - stdio

    func run() async {
        await withDiscardingTaskGroup { group in
            var buffer: [UInt8] = []
            while let chunk = await Self.readStdin() {
                buffer.append(contentsOf: chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = JS.trim(String(decoding: buffer[..<newline], as: UTF8.self))
                    buffer.removeSubrange(...newline)
                    if line.isEmpty { continue }
                    guard let message = try? JSON.parse(line) else {
                        send(JSONObject(["jsonrpc": .string("2.0"), "id": .null, "error": Self.error(-32700, "parse error")]))
                        continue
                    }
                    // Not awaited: a long sim_watch must not hold up the next request.
                    group.addTask { await self.handle(message) }
                }
            }
            // stdin closed: the group still waits for calls in flight.
        }
    }

    private static func readStdin() async -> [UInt8]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = read(0, &buffer, buffer.count)
                    if n < 0 && errno == EINTR { continue }
                    continuation.resume(returning: n > 0 ? Array(buffer[..<n]) : nil)
                    return
                }
            }
        }
    }

    private func send(_ message: JSONObject) {
        let data = Data((JSON.object(message).serialized() + "\n").utf8)
        outputLock.lock()
        defer { outputLock.unlock() }
        FileHandle.standardOutput.write(data)
    }

    private static func error(_ code: Int, _ message: String) -> JSON {
        .object(JSONObject(["code": .number(Double(code)), "message": .string(message)]))
    }

    // MARK: - JSON-RPC

    struct RpcError: Error {
        let code: Int
        let message: String
    }

    struct ToolError: Error, CustomStringConvertible {
        let description: String
    }

    func handle(_ msg: JSON) async {
        guard let object = msg.objectValue else {
            return send(JSONObject(["jsonrpc": .string("2.0"), "id": .null, "error": Self.error(-32600, "invalid request")]))
        }
        guard let id = object["id"] else { return } // notification
        let method = object["method"]
        let params = object["params"]
        func result(_ value: JSON) { send(JSONObject(["jsonrpc": .string("2.0"), "id": id, "result": value])) }
        do {
            guard let method = method?.stringValue else { throw RpcError(code: -32600, message: "invalid request: method must be a string") }
            switch method {
            case "initialize":
                let requested = params?["protocolVersion"]?.stringValue
                let version = requested.flatMap { r in Self.protocolVersions.first { JS.same($0, r) } } ?? Self.protocolVersions[0]
                return result(.object(JSONObject([
                    // Echo the client's version when we support it, otherwise offer our newest.
                    "protocolVersion": .string(version),
                    "capabilities": .object(JSONObject(["tools": .object(JSONObject())])),
                    "serverInfo": .object(JSONObject(["name": .string("sim-agentation"), "version": .string("0.1.0")])),
                    "instructions": .string(
                        "The user annotates a running iOS simulator in the browser (http://localhost:\(port)). "
                            + "Fetch annotations with sim_get_pending, Read the screenshot paths to see the UI, find the SwiftUI/UIKit code, fix it, then sim_resolve."
                    ),
                ])))
            case "ping":
                return result(.object(JSONObject()))
            case "tools/list":
                return result(.object(JSONObject([
                    "tools": .array(Self.tools.map { tool in
                        .object(JSONObject([
                            "name": .string(tool.name),
                            "description": .string(tool.description),
                            "inputSchema": .object(JSONObject([
                                "type": .string("object"),
                                "properties": .object(tool.properties),
                                "required": .array(tool.required.map(JSON.string)),
                            ])),
                        ]))
                    }),
                ])))
            case "tools/call":
                let name = params?["name"]
                guard let toolName = name?.stringValue, let tool = Self.tools.first(where: { JS.same($0.name, toolName) }) else {
                    throw RpcError(code: -32602, message: "unknown tool: \(JS.string(name))")
                }
                await ensureServer()
                let arguments = params?["arguments"].flatMap { $0.isNull ? nil : $0 } ?? .object(JSONObject())
                do {
                    let text = try await call(tool.name, arguments)
                    return result(.object(JSONObject(["content": Self.textContent(text)])))
                } catch {
                    return result(.object(JSONObject(["isError": .bool(true), "content": Self.textContent(AppServer.message(error))])))
                }
            default:
                send(JSONObject(["jsonrpc": .string("2.0"), "id": id, "error": Self.error(-32601, "method not found: \(method)")]))
            }
        } catch let error as RpcError {
            send(JSONObject(["jsonrpc": .string("2.0"), "id": id, "error": Self.error(error.code, error.message)]))
        } catch {
            send(JSONObject(["jsonrpc": .string("2.0"), "id": id, "error": Self.error(-32603, AppServer.message(error))]))
        }
    }

    private static func textContent(_ text: String) -> JSON {
        .array([.object(JSONObject(["type": .string("text"), "text": .string(text)]))])
    }

    // MARK: - tools

    struct Tool {
        let name: String
        let description: String
        let properties: JSONObject
        let required: [String]
    }

    private static let idArg: JSON = .object(JSONObject(["type": .string("string"), "description": .string("Annotation id (prefix is fine)")]))
    private static let stringArg: JSON = .object(JSONObject(["type": .string("string")]))

    static let tools: [Tool] = [
        Tool(
            name: "sim_get_pending",
            description: "List pending UI annotations the user drew on the iOS simulator, with element info and screenshot paths.",
            properties: JSONObject(), required: []
        ),
        Tool(
            name: "sim_get_all",
            description: "List every annotation, including acknowledged, resolved and dismissed ones.",
            properties: JSONObject(), required: []
        ),
        Tool(
            name: "sim_watch",
            description: "Wait until the user submits at least one annotation, then return the pending list. Use in a loop for hands-free mode.",
            properties: JSONObject([
                "timeout_seconds": .object(JSONObject(["type": .string("number"), "description": .string("Max wait, default 100, max 110")])),
            ]),
            required: []
        ),
        Tool(
            name: "sim_acknowledge",
            description: "Mark an annotation as being worked on. The user sees this in the browser.",
            properties: JSONObject(["id": idArg]), required: ["id"]
        ),
        Tool(
            name: "sim_resolve",
            description: "Mark an annotation as fixed, with a one-line summary of the change.",
            properties: JSONObject(["id": idArg, "summary": stringArg]), required: ["id", "summary"]
        ),
        Tool(
            name: "sim_dismiss",
            description: "Decline an annotation, with the reason.",
            properties: JSONObject(["id": idArg, "reason": stringArg]), required: ["id", "reason"]
        ),
        Tool(
            name: "sim_reply",
            description: "Post a message on an annotation, e.g. a question for the user.",
            properties: JSONObject(["id": idArg, "message": stringArg]), required: ["id", "message"]
        ),
    ]

    private func call(_ name: String, _ a: JSON) async throws -> String {
        let id = JS.string(a["id"])
        switch name {
        case "sim_get_pending":
            return render(try await request("/api/annotations?status=pending"), empty: "No pending annotations.")
        case "sim_get_all":
            return render(try await request("/api/annotations"), empty: "No annotations yet.")
        case "sim_watch":
            let timeout = JS.string(a["timeout_seconds"].flatMap { $0.isNull ? nil : $0 } ?? .number(100))
            return render(try await request("/api/wait?timeout=\(timeout)"), empty: "Nothing new yet; call sim_watch again to keep waiting.")
        case "sim_acknowledge":
            try await patch(id, JSONObject(["status": .string("acknowledged")]))
            return "Acknowledged \(id)."
        case "sim_resolve":
            try await patch(id, JSONObject(["status": .string("resolved"), "resolution": a["summary"]]))
            return "Resolved \(id)."
        case "sim_dismiss":
            try await patch(id, JSONObject(["status": .string("dismissed"), "resolution": a["reason"]]))
            return "Dismissed \(id)."
        case "sim_reply":
            try await patch(id, JSONObject(["reply": .object(JSONObject(["from": .string("agent"), "message": a["message"]]))]))
            return "Replied on \(id)."
        default:
            throw ToolError(description: "unknown tool: \(name)")
        }
    }

    private func render(_ list: JSON, empty: String) -> String {
        guard let items = list.arrayValue, !items.isEmpty else { return empty }
        let header = "\(items.count) annotation(s). Each has a screenshot path you can Read to see the UI.\n"
            + "Acknowledge one when you start on it, resolve it with a short summary when done."
        return ([header] + items.map { Format.toMarkdown($0.objectValue ?? JSONObject()) }).joined(separator: "\n\n")
    }

    private func patch(_ id: String, _ body: JSONObject) async throws {
        _ = try await request("/api/annotations/\(id)", method: "PATCH", body: .object(body))
    }

    // MARK: - HTTP

    private func url(_ path: String) throws -> URL {
        if let url = URL(string: api + path) { return url }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.union(.urlPathAllowed)) ?? path
        guard let url = URL(string: api + encoded) else { throw ToolError(description: "bad URL \(api + path)") }
        return url
    }

    private func request(_ path: String, method: String = "GET", body: JSON? = nil) async throws -> JSON {
        var request = URLRequest(url: try url(path))
        request.httpMethod = method
        if let body {
            request.httpBody = body.data()
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            throw ToolError(description: "Unable to connect. Is the computer able to access the url?")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try AppServer.parseBody(data)
        if !(200..<300).contains(status) {
            throw ToolError(description: JS.truthy(json["error"]) ? JS.string(json["error"]) : "HTTP \(status)")
        }
        return json
    }

    /// Starts `sim-agentation serve` from this executable if nothing answers.
    private func ensureServer() async {
        guard let probe = URL(string: "\(api)/api/annotations?status=pending"), let list = URL(string: "\(api)/api/annotations") else { return }
        if (try? await probeSession.data(from: probe)) != nil { return }
        spawnServer()
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            if (try? await session.data(from: list)) != nil { return }
        }
    }

    /// Detached: its own session, stdio on /dev/null, no inherited descriptors,
    /// so it outlives this process and never writes into the JSON-RPC stream.
    private func spawnServer() {
        let path = Config.executablePath
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // This runs on a worker thread whose signal mask blocks SIGTERM and friends;
        // the child would inherit it and ignore `kill`. Start it clean.
        var noSignals = sigset_t(), allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        )
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup("serve"), nil]
        defer { for arg in argv { free(arg) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
        if status != 0 {
            FileHandle.standardError.write(Data("sim-agentation: could not start the server (\(String(cString: strerror(status))))\n".utf8))
        }
    }
}
