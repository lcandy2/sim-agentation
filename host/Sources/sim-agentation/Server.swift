import Foundation
import SimBridge

/// The browser UI's server: static files, the annotation API, device chrome
/// and the simulator stream.
final class AppServer: @unchecked Sendable {
    typealias Request = HTTPServer.Request
    typealias Response = HTTPServer.Response

    let port: UInt16
    let store: Store
    let chrome: ChromeService
    /// Where the built UI lives (web/dist); files are read per request.
    let dist: String?
    let sdkSession: URLSession

    // Only this UI may talk to us. Host stops DNS rebinding; Origin stops other
    // pages in the user's browser (WebSockets and "simple" POSTs skip CORS).
    // Non-browser clients such as the MCP server send no Origin and are allowed.
    private let localHosts: Set<String>
    private let localOrigins: Set<String>

    /// Screenshots and recordings saved to the Desktop, by id: only these can be revealed.
    private var savedFiles: [String: String] = [:]
    private let savedLock = NSLock()

    init(port: UInt16, store: Store, chrome: ChromeService, dist: String?) {
        self.port = port
        self.store = store
        self.chrome = chrome
        self.dist = dist
        localHosts = ["localhost:\(port)", "127.0.0.1:\(port)"]
        localOrigins = Set(localHosts.map { "http://\($0)" })
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:] // loopback; never through a system proxy
        config.timeoutIntervalForRequest = 0.8
        config.timeoutIntervalForResource = 0.8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        sdkSession = URLSession(configuration: config)
    }

    // MARK: - responses

    static func json(_ value: JSON, status: Int = 200) -> Response {
        Response(status: status, headers: ["Content-Type": "application/json;charset=utf-8"], body: value.data())
    }

    static func json(_ object: JSONObject, status: Int = 200) -> Response { json(.object(object), status: status) }

    static func text(_ text: String, status: Int) -> Response { Response.text(text, status: status) }

    static let notFound = text("not found", status: 404)

    private static let mimeTypes: [String: String] = [
        "html": "text/html;charset=utf-8", "htm": "text/html;charset=utf-8",
        "js": "text/javascript;charset=utf-8", "mjs": "text/javascript;charset=utf-8",
        "css": "text/css;charset=utf-8", "json": "application/json;charset=utf-8", "map": "application/json;charset=utf-8",
        "txt": "text/plain;charset=utf-8", "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg",
        "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "ico": "image/x-icon", "avif": "image/avif",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf", "wasm": "application/wasm",
    ]

    /// A regular file, or 404.
    static func file(_ path: String, _ headers: [String: String]) async -> Response {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let data = try? await blocking({ try Data(contentsOf: URL(fileURLWithPath: path)) })
        else { return notFound }
        var headers = headers
        let ext = (path as NSString).pathExtension.lowercased()
        headers["Content-Type"] = mimeTypes[ext] ?? "application/octet-stream"
        return Response(status: 200, headers: headers, body: data)
    }

    private func rejectForeign(_ req: Request) -> Response? {
        if !localHosts.contains(req.header("host") ?? "") { return Self.text("forbidden host", status: 403) }
        if let origin = req.header("origin"), !origin.isEmpty, !localOrigins.contains(origin) {
            return Self.text("forbidden origin", status: 403)
        }
        let writes = req.method == "POST" || req.method == "PATCH"
        if writes && !(req.header("content-type")?.hasPrefix("application/json") ?? false) {
            return Self.text("expected application/json", status: 415)
        }
        return nil
    }

    // MARK: - routing

    func handle(_ req: Request) async -> HTTPServer.Outcome {
        let path = req.path
        let parts = path.split(separator: "/").map(String.init)
        func part(_ i: Int) -> String? { i < parts.count ? parts[i] : nil }
        if let forbidden = rejectForeign(req) { return .respond(forbidden) }

        do {
            // no-store: the UI changes often during development and stale modules break it silently.
            let fresh = ["Cache-Control": "no-store"]
            // The Vite build of web/.
            if let dist {
                if path == "/" || path == "/index.html" { return .respond(await Self.file(Path.join(dist, "index.html"), fresh)) }
                if part(0) == "assets" && parts.count >= 2 {
                    guard let relative = Self.safeRelativePath(parts.dropFirst()) else { return .respond(Self.notFound) }
                    return .respond(await Self.file(Path.join(dist, "assets", relative), fresh))
                }
            }
            // Image names carry the annotation id and never change.
            if part(0) == "images" && parts.count == 2 {
                guard Self.safeSegment(parts[1]) else { return .respond(Self.notFound) }
                return .respond(await Self.file(Path.join(store.images, parts[1]), ["Cache-Control": "private, max-age=31536000, immutable"]))
            }

            // The simulator stream: screen frames out, input and describe_ui in.
            if part(0) == "ws", let udid = part(1) {
                var options = StreamOptions()
                if let format = req.queryValue("format").flatMap(StreamFormat.init(rawValue:)) { options.format = format }
                if let fps = req.queryValue("fps").flatMap(Int.init), fps > 0 { options.fps = min(fps, 120) }
                if let bps = req.queryValue("bitrate").flatMap(Int.init), bps > 0 { options.bitrate = bps }
                if let scale = req.queryValue("scale").flatMap(Int.init), scale > 0 { options.scale = min(scale, 4) }
                let chosen = options
                return .upgrade { socket in DeviceSession(udid: udid, socket: socket, options: chosen).start() }
            }

            // Device chrome artwork: rasterized once, then immutable.
            let forever = ["Cache-Control": "public, max-age=31536000, immutable"]
            if part(0) == "chrome" && parts.count == 3 && parts[2].hasSuffix(".png") {
                let name = try JS.decodeURIComponent(String(parts[2].dropLast(4)))
                let png = try await chrome.chromeImage(id: parts[1], name: name)
                return .respond(png != nil ? await Self.file(png!, forever) : Self.notFound)
            }

            if path == "/api/sims" && req.method == "POST" {
                return .respond(Self.json(try await createDevice(try Self.parseBody(req.body)), status: 201))
            }
            if path == "/api/sims" { return .respond(Self.json(try await devices())) }
            if path == "/api/sims/new" { return .respond(Self.json(try await deviceOptions())) }
            if part(0) == "api" && part(1) == "sims" && part(3) == "chrome" {
                return .respond(Self.json(try await chrome.chrome(for: parts[2])))
            }
            if part(0) == "api" && part(1) == "sims" && part(3) == "mask.png" {
                let png = try await chrome.maskImage(udid: parts[2])
                return .respond(png != nil ? await Self.file(png!, forever) : Self.notFound)
            }
            if part(0) == "api" && part(1) == "sims" && part(3) == "boot" && req.method == "POST" {
                try await boot(parts[2])
                // Once it's up, take its buttons back if Device Hub claims them:
                // nothing runs yet, so restarting SpringBoard costs nothing.
                let udid = parts[2]
                Task.detached { await InputSurface.healAfterBoot(udid: udid) }
                return .respond(Self.json(JSONObject(["ok": .bool(true)])))
            }
            // Device Hub's … menu: shut down, restart, rename, reset, remove.
            if part(0) == "api" && part(1) == "sims", let udid = part(2), parts.count <= 4,
               ["shutdown", "restart", "rename", "erase", nil].contains(part(3)),
               (req.method == "POST" && part(3) != nil) || (req.method == "DELETE" && part(3) == nil) {
                guard let device = (try? await blocking { Simulators.shared.find(udid) }) ?? nil else {
                    return .respond(Self.json(JSONObject(["error": .string("no simulator \(udid)")]), status: 404))
                }
                try await manage(device, action: part(3) ?? "delete", body: req.body)
                return .respond(Self.json(JSONObject(["ok": .bool(true)])))
            }
            // Simulator.app's Save Screen and Record Screen: the file goes where it puts them.
            if path == "/api/screenshots" && req.method == "POST" {
                return .respond(Self.json(try await saveScreenshot(req), status: 201))
            }
            if path == "/api/recordings" && req.method == "POST" {
                return .respond(Self.json(try await saveRecording(req), status: 201))
            }
            if part(0) == "api", part(1) == "screenshots" || part(1) == "recordings", let id = part(2), part(3) == "reveal", req.method == "POST" {
                let file = savedLock.withLock { savedFiles[id] }
                guard let file, FileManager.default.fileExists(atPath: file) else {
                    return .respond(Self.json(JSONObject(["error": .string("no such file")]), status: 404))
                }
                _ = try await blocking { try run(["open", "-R", file]) }
                return .respond(Self.json(JSONObject(["ok": .bool(true)])))
            }
            // Simulator.app's Features menu: appearance, text size, shake, Face ID.
            if part(0) == "api" && part(1) == "sims", let udid = part(2), part(3) == "feature", req.method == "POST" {
                guard let name = try Self.parseBody(req.body)["name"]?.stringValue else { throw BadRequest("name is required") }
                let value = try await feature(udid, name: name)
                return .respond(Self.json(JSONObject(["ok": .bool(true), "value": .string(value)])))
            }
            if part(0) == "api" && part(1) == "sims", let udid = part(2), part(3) == "input", req.method == "GET" {
                let shadowed = await InputSurface.shadowed(udid: udid)
                return .respond(Self.json(JSONObject(["shadowed": .bool(shadowed)])))
            }
            if part(0) == "api" && part(1) == "sims", let udid = part(2), part(3) == "reclaim", req.method == "POST" {
                try await InputSurface.reclaim(udid: udid)
                return .respond(Self.json(JSONObject(["ok": .bool(true)])))
            }

            // SimAgentationPlus runs inside the app; the simulator shares our loopback.
            // Hot reload: the dev server `pnpm dev` runs leaves a token and its
            // process id beside the build. While that process lives the page
            // gets the token, and loads from the dev server only if it answers
            // with it (web/src/main.js); a note left by one that died is ignored.
            if path == "/api/dev" {
                guard let dist, let note = FileManager.default.contents(atPath: Path.join((dist as NSString).deletingLastPathComponent, ".dev-server.json")),
                      let dev = try? JSON.parse(note),
                      let token = dev["token"]?.stringValue, let pid = dev["pid"]?.numberValue,
                      pid > 0, pid < Double(Int32.max), kill(pid_t(pid), 0) == 0
                else { return .respond(Response(status: 204, headers: [:], body: Data())) }
                return .respond(Self.json(JSONObject(["token": .string(token)])))
            }
            if path == "/api/sdk" { return .respond(await sdkSnapshot()) }
            if path == "/api/annotations" && req.method == "GET" {
                return .respond(Self.json(.array(store.list(status: req.queryValue("status")).map(JSON.object))))
            }
            if path == "/api/annotations" && req.method == "POST" {
                return .respond(Self.json(try await createAnnotation(try Self.parseBody(req.body)), status: 201))
            }
            if path == "/api/annotations/finished" && req.method == "DELETE" {
                try store.clearFinished()
                return .respond(Self.json(JSONObject(["ok": .bool(true)])))
            }
            if path == "/api/wait" {
                let requested = req.queryValue("timeout").map(JS.number) ?? 0
                let timeout = min(requested > 0 ? requested : 60, 110) // seconds
                let deadline = ContinuousClock.now + .milliseconds(Int64((timeout * 1000).rounded(.down)))
                while true {
                    let (pending, version) = store.pending()
                    if !pending.isEmpty || ContinuousClock.now >= deadline { break }
                    await store.waitForChange(since: version, until: deadline)
                }
                return .respond(Self.json(.array(store.list(status: "pending").map(JSON.object))))
            }
            if part(0) == "api" && part(1) == "annotations", let id = part(2) {
                guard let a = store.get(id) else { return .respond(Self.json(JSONObject(["error": .string("not found")]), status: 404)) }
                let fullId = a["id"]?.stringValue ?? id
                if req.method == "GET" {
                    var withMarkdown = a
                    withMarkdown["markdown"] = .string(Format.toMarkdown(a))
                    return .respond(Self.json(withMarkdown))
                }
                if req.method == "DELETE" { return .respond(Self.json(JSONObject(["ok": .bool(try store.remove(fullId))]))) }
                if req.method == "PATCH" {
                    let (patch, reply) = try Self.parsePatch(try Self.parseBody(req.body))
                    let updated = try store.update(fullId, patch: patch, reply: reply)
                    return .respond(Self.json(updated.map(JSON.object) ?? .null))
                }
            }

            // Other files at the top of the Vite build (favicon and the like).
            if let dist, parts.count == 1, let name = parts[0].removingPercentEncoding, Self.safeSegment(name) {
                return .respond(await Self.file(Path.join(dist, name), fresh))
            }
            return .respond(Self.notFound)
        } catch {
            let bad = error is BadRequest || error is BodySyntaxError
            return .respond(Self.json(JSONObject(["error": .string(Self.message(error))]), status: bad ? 400 : 500))
        }
    }

    /// The error's message: our own errors describe themselves, Cocoa errors localize.
    static func message(_ error: Error) -> String {
        if type(of: error) is NSError.Type || error is URLError || error is CocoaError { return error.localizedDescription }
        return String(describing: error)
    }

    private static func isFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// One path segment that can't climb out of its directory.
    private static func safeSegment(_ segment: String) -> Bool {
        !segment.isEmpty && segment != "." && segment != ".." && !segment.contains("/") && !segment.contains("\0")
    }

    /// Percent-decoded segments joined back into a relative path, or nil if any is unsafe.
    private static func safeRelativePath(_ segments: ArraySlice<String>) -> String? {
        var out: [String] = []
        for segment in segments {
            guard let decoded = segment.removingPercentEncoding, safeSegment(decoded) else { return nil }
            out.append(decoded)
        }
        return out.joined(separator: "/")
    }

    // MARK: - simulators

    private func devices() async throws -> JSON {
        let list = try await blocking { Simulators.shared.all() }
        return .array(list.map { d in
            .object(JSONObject([
                "udid": .string(d.udid), "name": .string(d.name), "runtime": .string(d.runtime),
                "state": .string(d.state.rawValue), "deviceType": .string(d.deviceType),
            ]))
        })
    }

    /// What a new simulator can be: device types, and the available
    /// runtimes with the device types each supports.
    private func deviceOptions() async throws -> JSON {
        let list = try await blocking { try JSON.parse(try run(["xcrun", "simctl", "list", "devicetypes", "runtimes", "-j"])) }
        let types = (list["devicetypes"]?.arrayValue ?? []).compactMap { t -> JSON? in
            guard let id = t["identifier"]?.stringValue, let name = t["name"]?.stringValue else { return nil }
            return .object(JSONObject(["identifier": .string(id), "name": .string(name), "family": t["productFamily"] ?? .null]))
        }
        let runtimes = (list["runtimes"]?.arrayValue ?? []).compactMap { r -> JSON? in
            guard case .bool(true)? = r["isAvailable"], let id = r["identifier"]?.stringValue, let name = r["name"]?.stringValue else { return nil }
            let supported = (r["supportedDeviceTypes"]?.arrayValue ?? []).compactMap { $0["identifier"] }
            return .object(JSONObject(["identifier": .string(id), "name": .string(name), "platform": r["platform"] ?? .null, "deviceTypes": .array(supported)]))
        }
        return .object(JSONObject(["deviceTypes": .array(types), "runtimes": .array(runtimes)]))
    }

    /// `simctl create`; the new device starts shut down.
    private func createDevice(_ body: JSON) async throws -> JSONObject {
        guard let name = body["name"]?.stringValue.map(JS.trim), !name.isEmpty,
              let type = body["deviceType"]?.stringValue, type.hasPrefix("com.apple.CoreSimulator.SimDeviceType."),
              let runtime = body["runtime"]?.stringValue, runtime.hasPrefix("com.apple.CoreSimulator.SimRuntime.")
        else { throw BadRequest("name, deviceType and runtime are required") }
        let udid = try await blocking { try run(["xcrun", "simctl", "create", name, type, runtime]) }
        return JSONObject(["udid": .string(JS.trim(udid))])
    }

    /// `simctl` for the … menu. Erasing needs the device shut down; one that
    /// was running comes back up afterwards (and gets its buttons back, as
    /// any boot does). Removing shuts it down first.
    private func manage(_ device: SimulatorDevice, action: String, body: Data) async throws {
        let udid = device.udid
        let running = device.state == .booted
        switch action {
        case "shutdown":
            try await blocking { try Simulators.shared.shutdown(udid) }
        case "restart":
            try await blocking { try Simulators.shared.shutdown(udid) }
            try await boot(udid)
            Task.detached { await InputSurface.healAfterBoot(udid: udid) }
        case "rename":
            guard let name = try Self.parseBody(body)["name"]?.stringValue.map(JS.trim), !name.isEmpty else {
                throw BadRequest("name is required")
            }
            _ = try await blocking { try run(["xcrun", "simctl", "rename", udid, name]) }
        case "erase":
            if running { try await blocking { try Simulators.shared.shutdown(udid) } }
            _ = try await blocking { try run(["xcrun", "simctl", "erase", udid]) }
            if running {
                try await boot(udid)
                Task.detached { await InputSurface.healAfterBoot(udid: udid) }
            }
        default: // delete
            if running { try? await blocking { try Simulators.shared.shutdown(udid) } }
            _ = try await blocking { try run(["xcrun", "simctl", "delete", udid]) }
        }
    }

    /// Saves a screenshot as Simulator.app's Save Screen does: on the Desktop,
    /// "Simulator Screenshot - <device> - <date> at <time>.png". Takes
    /// { udid, png: base64 } (JSON, as every write here) and PNGs only; the
    /// device's name comes from the host's own list.
    private func saveScreenshot(_ req: Request) async throws -> JSONObject {
        let body = try Self.parseBody(req.body)
        guard let encoded = body["png"]?.stringValue, let png = Data(base64Encoded: encoded),
              png.count <= 64 << 20, png.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        else { throw BadRequest("a PNG is required") }
        return try await saveToDesktop(png, as: "Simulator Screenshot", ext: "png", udid: body["udid"]?.stringValue ?? "")
    }

    /// Saves a screen recording as Simulator.app's Record Screen does: on the
    /// Desktop, "Simulator Screen Recording - <device> - <date> at <time>",
    /// as the page recorded it. Takes { udid, video: base64 } and MP4 or WebM
    /// only (by their signatures).
    private func saveRecording(_ req: Request) async throws -> JSONObject {
        let body = try Self.parseBody(req.body)
        guard let encoded = body["video"]?.stringValue, let video = Data(base64Encoded: encoded), video.count <= 96 << 20
        else { throw BadRequest("a video is required") }
        let ext: String
        if video.count > 8, video[video.startIndex + 4 ..< video.startIndex + 8].elementsEqual(Array("ftyp".utf8)) { ext = "mp4" }
        else if video.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { ext = "webm" }
        else { throw BadRequest("an MP4 or WebM video is required") }
        return try await saveToDesktop(video, as: "Simulator Screen Recording", ext: ext, udid: body["udid"]?.stringValue ?? "")
    }

    /// Writes data to the Desktop under Simulator.app's naming, "<what> -
    /// <device> - <date> at <time>.<ext>", numbered rather than overwriting,
    /// and remembers it for Open in Finder. The device's name comes from the
    /// host's own list.
    private func saveToDesktop(_ data: Data, as what: String, ext: String, udid: String) async throws -> JSONObject {
        let device = (try? await blocking { Simulators.shared.find(udid) }) ?? nil
        let name = (device?.name ?? "Simulator").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        let base = "\(what) - \(name) - \(stamp.string(from: Date()))"
        var file = desktop.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = desktop.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        try data.write(to: file, options: .withoutOverwriting)
        let id = UUID().uuidString
        savedLock.withLock { savedFiles[id] = file.path }
        return JSONObject(["id": .string(id), "name": .string(file.lastPathComponent)])
    }

    /// Simulator.app's Features, through simctl: toggles the appearance, steps
    /// the preferred text size, shakes, matches or fails Face ID and Touch ID
    /// (a device listens for its own kind). Returns what it set.
    private func feature(_ udid: String, name: String) async throws -> String {
        func simctl(_ args: [String]) async throws -> String {
            JS.trim(try await blocking { try run(["xcrun", "simctl"] + args) })
        }
        switch name {
        case "appearance":
            let next = try await simctl(["ui", udid, "appearance"]) == "dark" ? "light" : "dark"
            _ = try await simctl(["ui", udid, "appearance", next])
            return next
        case "text-bigger", "text-smaller":
            _ = try await simctl(["ui", udid, "content_size", name == "text-bigger" ? "increment" : "decrement"])
            return try await simctl(["ui", udid, "content_size"])
        case "shake":
            _ = try await simctl(["notify_post", udid, "com.apple.UIKit.SimulatorShake"])
            return name
        case "biometric-match", "biometric-mismatch":
            let outcome = name == "biometric-match" ? "match" : "nomatch"
            for kind in ["pearl", "fingerTouch"] {
                _ = try await simctl(["notify_post", udid, "com.apple.BiometricKit_Sim.\(kind).\(outcome)"])
            }
            return name
        default:
            throw BadRequest("no feature \(name)")
        }
    }

    private func boot(_ udid: String) async throws {
        try await blocking { try Simulators.shared.boot(udid) }
    }

    private func sdkSnapshot() async -> Response {
        guard let url = URL(string: "\(Config.sdkURL)/snapshot"),
              let (data, response) = try? await sdkSession.data(from: url),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
              let snapshot = try? JSON.parse(data)
        else { return Response(status: 204, headers: [:], body: Data()) }
        return Self.json(snapshot)
    }

    // MARK: - annotations

    struct BadRequest: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// A body that isn't JSON.
    struct BodySyntaxError: Error, CustomStringConvertible {
        let description: String
    }

    static func parseBody(_ body: Data) throws -> JSON {
        if body.isEmpty { throw BodySyntaxError(description: "Unexpected end of JSON input") }
        do { return try JSON.parse(body) } catch { throw BodySyntaxError(description: "Failed to parse JSON") }
    }

    private static func isRect(_ r: JSON?) -> Bool {
        guard r?.objectValue != nil else { return false }
        return ["x", "y", "width", "height"].allSatisfy { JS.isFiniteNumber(r?[$0]) }
    }

    private func createAnnotation(_ body: JSON) async throws -> JSONObject {
        guard let b = body.objectValue else { throw BadRequest("expected a JSON object") }
        guard let comment = b["comment"]?.stringValue, !JS.trim(comment).isEmpty else { throw BadRequest("comment is required") }
        guard let udid = b["udid"]?.stringValue, Self.isRect(b["rect"]) else { throw BadRequest("udid and rect are required") }
        guard let full = b["full"]?.stringValue, let crop = b["crop"]?.stringValue else {
            throw BadRequest("full and crop images are required")
        }
        let rect = b["rect"]!
        let tree = b["tree"]?.objectValue
        let point = b["point"]?.objectValue != nil && JS.isFiniteNumber(b["point"]?["x"]) && JS.isFiniteNumber(b["point"]?["y"])
            ? b["point"] : nil

        var hit: AX.Entry?
        if JS.same(b["kind"]?.stringValue, "element"), let point, let tree {
            hit = AX.hitTest(tree, x: JS.number(point["x"]), y: JS.number(point["y"]))
        }
        // An area (a box, or an icon or text run found in the pixels) names the
        // innermost element it sits in, so the agent knows where to look.
        func center(_ r: JSON) -> AX.Entry? {
            guard let tree, let x = r["x"], let y = r["y"], let w = r["width"], let h = r["height"] else { return nil }
            return AX.hitTest(tree, x: JS.number(x) + JS.number(w) / 2, y: JS.number(y) + JS.number(h) / 2)
        }
        // Several picked at once (Shift): the box holds them all, and each part
        // names its element as a single pick does.
        let parts: [JSON] = (b["parts"]?.arrayValue ?? []).prefix(20).compactMap { part in
            guard Self.isRect(part["rect"]), let partRect = part["rect"] else { return nil }
            var partHit: AX.Entry?
            if JS.same(part["kind"]?.stringValue, "element"), let tree, let p = part["point"],
               JS.isFiniteNumber(p["x"]), JS.isFiniteNumber(p["y"]) {
                partHit = AX.hitTest(tree, x: JS.number(p["x"]), y: JS.number(p["y"]))
            }
            let partWithin = partHit == nil ? center(partRect) : nil
            return .object(JSONObject([
                "kind": .string(partHit != nil ? "element" : "area"),
                "rect": partRect,
                "label": part["label"]?.stringValue.map { .string(JS.trim($0)) } ?? .null,
                // The color its box is drawn in, on screen and in the screenshot: a name.
                "color": part["color"]?.stringValue.flatMap { $0.count < 16 && $0.allSatisfy(\.isLetter) ? JSON.string($0) : nil } ?? .null,
                "target": partHit.map { AX.summarize($0.node) } ?? .null,
                "within": partWithin.map { AX.summarize($0.node) } ?? .null,
                "source": part["source"]?.arrayValue != nil ? part["source"]! : .array([]),
            ]))
        }
        let within = hit == nil && parts.count < 2 ? center(rect) : nil
        let device = (try? await blocking { Simulators.shared.all() })?.first { $0.udid == udid }
        let id = Store.newId()
        let now = Store.timestamp()
        let images = JSONObject([
            "full": .string(Path.join(store.images, "\(id)-full.jpg")),
            "crop": .string(Path.join(store.images, "\(id)-crop.jpg")),
        ])
        let annotation = JSONObject([
            "id": .string(id),
            "createdAt": .string(now),
            "updatedAt": .string(now),
            "status": .string("pending"),
            "comment": .string(JS.trim(comment)),
            "kind": .string(hit != nil ? "element" : "area"),
            "device": .object(JSONObject([
                "udid": .string(udid),
                "name": device.map { .string($0.name) } ?? .null,
                "runtime": device.map { .string($0.runtime) } ?? .null,
            ])),
            "rect": rect,
            "label": b["label"]?.stringValue.map { .string(JS.trim($0)) } ?? .null,
            "target": hit.map { AX.summarize($0.node) } ?? .null,
            "within": within.map { AX.summarize($0.node) } ?? .null,
            "targetPath": .array((hit?.path.dropFirst() ?? []).map(JSON.string)),
            "parts": .array(parts.count > 1 ? parts : []),
            "inside": .array(tree.map { AX.nodesInRect($0, rect).prefix(20).map { AX.summarize($0.node) } } ?? []),
            "screen": AX.screenContext(tree),
            "app": b["app"]?.objectValue != nil
                ? b["app"]!
                : .object(JSONObject([
                    "bundleId": .null,
                    "name": tree.flatMap { JS.trimmed($0["label"]) }.flatMap { $0.isEmpty ? nil : JSON.string($0) } ?? .null,
                ])),
            "source": b["source"]?.arrayValue != nil ? b["source"]! : .array([]),
            "views": b["views"]?.arrayValue != nil ? b["views"]! : .array([]),
            "controller": b["controller"]?.stringValue.map(JSON.string) ?? .null,
            "images": .object(images),
            "replies": .array([]),
            "resolution": .null,
        ])
        // Images last, so a rejected request leaves nothing behind.
        try await blocking {
            try FileManager.default.createDirectory(atPath: self.store.images, withIntermediateDirectories: true)
            try Self.decodeBase64(full).write(to: URL(fileURLWithPath: images["full"]!.stringValue!))
            try Self.decodeBase64(crop).write(to: URL(fileURLWithPath: images["crop"]!.stringValue!))
        }
        return try store.add(annotation)
    }

    /// Buffer.from(s, 'base64'): lenient about padding, URL-safe characters
    /// and junk, the way Node decodes.
    static func decodeBase64(_ s: String) -> Data {
        if let data = Data(base64Encoded: s) { return data }
        var out = Data()
        var accumulator: UInt32 = 0
        var bits = 0
        for byte in s.utf8 {
            let value: UInt32
            switch byte {
            case 65...90: value = UInt32(byte - 65)
            case 97...122: value = UInt32(byte - 71)
            case 48...57: value = UInt32(byte + 4)
            case UInt8(ascii: "+"), UInt8(ascii: "-"): value = 62
            case UInt8(ascii: "/"), UInt8(ascii: "_"): value = 63
            case UInt8(ascii: "="): return out
            default: continue
            }
            accumulator = accumulator << 6 | value
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((accumulator >> UInt32(bits)) & 0xFF))
            }
        }
        return out
    }

    private static func parsePatch(_ body: JSON) throws -> ([(String, JSON)], JSON?) {
        guard let b = body.objectValue else { throw BadRequest("expected a JSON object") }
        var patch: [(String, JSON)] = []
        if let status = b["status"] {
            guard let s = status.stringValue, Store.statuses.contains(where: { JS.same($0, s) }) else {
                throw BadRequest("bad status \(JS.string(status))")
            }
            patch.append(("status", status))
        }
        if let resolution = b["resolution"] {
            guard resolution.isNull || resolution.stringValue != nil else { throw BadRequest("resolution must be a string or null") }
            patch.append(("resolution", resolution))
        }
        var reply: JSON?
        if let r = b["reply"] {
            let from = r["from"]?.stringValue
            guard r.objectValue != nil, JS.same(from, "agent") || JS.same(from, "human"),
                  let message = r["message"]?.stringValue, !JS.trim(message).isEmpty
            else { throw BadRequest("reply must be { from: \"agent\" | \"human\", message: string }") }
            reply = .object(JSONObject([
                "from": .string(from!), "message": .string(JS.trim(message)), "at": .string(Store.timestamp()),
            ]))
        }
        return (patch, reply)
    }
}
