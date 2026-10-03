import Foundation
import SimBridge

// sim-agentation host. For now it serves the simulator side the web UI
// needs (device list, boot, the stream socket); the annotation server moves
// here next.

let arguments = CommandLine.arguments.dropFirst()
let port = arguments.firstIndex(of: "--port").flatMap { arguments.index(after: $0) < arguments.endIndex ? UInt16(arguments[arguments.index(after: $0)]) : nil } ?? 38472

func deviceJSON(_ d: SimulatorDevice) -> [String: Any] {
    ["udid": d.udid, "name": d.name, "runtime": d.runtime, "state": d.state.rawValue, "deviceType": d.deviceType]
}

/// Matches a path against a pattern like "/api/devices/:udid/boot" and
/// returns the captured segments, or nil.
func route(_ request: HTTPServer.Request, _ method: String, _ pattern: String) -> [String]? {
    guard request.method == method else { return nil }
    let path = request.path.split(separator: "/").map(String.init)
    let want = pattern.split(separator: "/").map(String.init)
    guard path.count == want.count else { return nil }
    var captured: [String] = []
    for (segment, expected) in zip(path, want) {
        if expected.hasPrefix(":") { captured.append(segment.removingPercentEncoding ?? segment) }
        else if segment != expected { return nil }
    }
    return captured
}

let server = try HTTPServer(port: port) { request in
    if route(request, "GET", "/simulators") != nil || route(request, "GET", "/health") != nil {
        return .respond(.json(["ok": true]))
    }
    if route(request, "GET", "/api/devices") != nil {
        return .respond(.json(Simulators.shared.all().map(deviceJSON)))
    }
    if let udid = route(request, "POST", "/api/devices/:udid/boot")?.first {
        do {
            try Simulators.shared.boot(udid)
            return .respond(.json(["ok": true]))
        } catch {
            return .respond(.json(["error": "\(error)"], status: 500))
        }
    }
    if let udid = route(request, "GET", "/simulators/:udid/stream")?.first {
        guard Simulators.shared.find(udid) != nil else { return .respond(.text("no simulator \(udid)", status: 404)) }
        return .upgrade { socket in DeviceSession(udid: udid, socket: socket).start() }
    }
    return .respond(.text("not found", status: 404))
}

try await server.start()
FileHandle.standardError.write(Data("sim-agentation host on http://127.0.0.1:\(port)\n".utf8))
while true { try await Task.sleep(for: .seconds(3600)) }
