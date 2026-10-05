import Foundation

/// Settings from the environment.
enum Config {
    /// This release. The release workflow checks its tag against it.
    static let version = "0.2.1"

    static let environment = ProcessInfo.processInfo.environment

    static func env(_ name: String) -> String? {
        guard let value = environment[name], !value.isEmpty else { return nil }
        return value
    }

    /// SIM_AGENTATION_PORT, default 38470.
    static let defaultPort: UInt16 = {
        guard let value = env("SIM_AGENTATION_PORT") else { return 38470 }
        let number = JS.number(value)
        guard number.isFinite, number >= 0, number <= 65535, number == number.rounded() else { return 38470 }
        return UInt16(number)
    }()

    /// SIM_AGENTATION_HOME, default sim-agentation in the user's temporary
    /// directory: annotations and their screenshots. They're a handoff to an
    /// agent, kept through a restart of the host but not of the Mac.
    static let home: String = env("SIM_AGENTATION_HOME") ?? Path.join(NSTemporaryDirectory(), "sim-agentation")

    /// Rendered device chrome, which can always be made again: in the user's
    /// Caches folder, where macOS may clear it.
    static let cacheDirectory: String = Path.join(
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? Path.join(homeDirectory, "Library/Caches"),
        "sim-agentation"
    )

    /// SimAgentationPlus, the optional in-app SDK.
    static let sdkURL: String = env("SIM_AGENTATION_SDK_URL") ?? "http://127.0.0.1:38471"

    static var homeDirectory: String { env("HOME") ?? NSHomeDirectory() }

    /// This executable, symlinks resolved.
    static var executablePath: String {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// The web UI's source: SIM_AGENTATION_WEB, else the `web/` directory
    /// found by walking up from this executable (host/.build/debug/… sits
    /// inside the repo), else from the working directory. The server serves
    /// its Vite build, `web/dist`.
    static let webDirectory: String? = {
        if let web = env("SIM_AGENTATION_WEB") { return web }
        let fm = FileManager.default
        for start in [(executablePath as NSString).deletingLastPathComponent, fm.currentDirectoryPath] {
            var dir = start
            while true {
                let web = (dir as NSString).appendingPathComponent("web")
                if fm.fileExists(atPath: (web as NSString).appendingPathComponent("index.html")) {
                    return web
                }
                let parent = (dir as NSString).deletingLastPathComponent
                if parent == dir || parent.isEmpty { break }
                dir = parent
            }
        }
        return nil
    }()
}

/// Node's path.join and path.normalize (POSIX), so stored paths match.
enum Path {
    static func join(_ parts: String...) -> String {
        let nonEmpty = parts.filter { !$0.isEmpty }
        return nonEmpty.isEmpty ? "." : normalize(nonEmpty.joined(separator: "/"))
    }

    static func normalize(_ path: String) -> String {
        if path.isEmpty { return "." }
        let absolute = path.hasPrefix("/")
        let trailing = path.hasSuffix("/")
        var out: [Substring] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            if segment == "." { continue }
            if segment == ".." {
                if let last = out.last, last != ".." { out.removeLast() } else if !absolute { out.append("..") }
                continue
            }
            out.append(segment)
        }
        var result = out.joined(separator: "/")
        if result.isEmpty && !absolute { result = "." }
        if !result.isEmpty && trailing { result += "/" }
        return absolute ? "/" + result : result
    }
}
