import CoreGraphics
import Foundation
import ImageIO

// Device chrome (the bezel and hardware buttons) the way Xcode's Device Hub
// and Simulator find it: simulator → device type → profile.plist's
// chromeIdentifier → /Library/Developer/DeviceKit/Chrome/<id>.devicechrome.
// Artwork ships as PDFs; they're rasterized at 3× with CoreGraphics and the
// PNGs cached under `cache` (the user's Caches folder, see Config.cacheDirectory).

final class ChromeService: @unchecked Sendable {
    private static let root = "/Library/Developer/DeviceKit/Chrome"
    private static let scale = 3.0 // pixels per point in the rasterized artwork
    private static let slices = ["topLeft", "top", "topRight", "right", "bottomRight", "bottom", "bottomLeft", "left"]

    let cache: String
    private let lock = NSLock()
    // Files under /Library don't change while we run, so read each one once.
    private var plists: [String: Task<JSON, Error>] = [:]
    private var pdfSizes: [String: Task<CGSize, Error>] = [:]
    private var deviceTypes: Task<[String: String], Error>? // identifier → bundle path
    private var deviceTypeOf: (at: Date, map: Task<[String: String], Error>)? // udid → identifier
    private var chromes: [String: Task<JSON, Error>] = [:] // by udid

    init(cache: String) {
        self.cache = cache
    }

    // MARK: - lookups

    private func memo<T: Sendable>(
        _ table: ReferenceWritableKeyPath<ChromeService, [String: Task<T, Error>]>,
        _ key: String,
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let task: Task<T, Error> = lock.withLock {
            if let task = self[keyPath: table][key] { return task }
            let task = Task { try await blocking(body) }
            self[keyPath: table][key] = task
            return task
        }
        return try await task.value
    }

    private func plist(_ path: String) async throws -> JSON {
        try await memo(\.plists, path) { try Self.readPlist(path) }
    }

    /// PDF page size in points.
    private func pdfSize(_ path: String) async throws -> CGSize {
        try await memo(\.pdfSizes, path) { try Self.pdfPage(path).getBoxRect(.cropBox).size }
    }

    private func bundlePaths() async throws -> [String: String] {
        let task: Task<[String: String], Error> = lock.withLock {
            if let deviceTypes { return deviceTypes }
            let task = Task {
                try await blocking {
                    let list = try JSON.parse(try run(["xcrun", "simctl", "list", "devicetypes", "-j"]))
                    var map: [String: String] = [:]
                    for t in list["devicetypes"]?.arrayValue ?? [] {
                        if let id = t["identifier"]?.stringValue, let path = t["bundlePath"]?.stringValue { map[id] = path }
                    }
                    return map
                }
            }
            deviceTypes = task
            return task
        }
        return try await task.value
    }

    private func deviceTypeIds() async throws -> [String: String] {
        // Devices come and go; refresh the list every 30 s.
        let task: Task<[String: String], Error> = lock.withLock {
            if let cached = deviceTypeOf, Date().timeIntervalSince(cached.at) <= 30 { return cached.map }
            let task = Task {
                try await blocking {
                    let list = try JSON.parse(try run(["xcrun", "simctl", "list", "devices", "-j"]))
                    var map: [String: String] = [:]
                    for (_, devices) in list["devices"]?.objectValue?.entries ?? [] {
                        for d in devices.arrayValue ?? [] {
                            if let udid = d["udid"]?.stringValue, let type = d["deviceTypeIdentifier"]?.stringValue { map[udid] = type }
                        }
                    }
                    return map
                }
            }
            deviceTypeOf = (Date(), task)
            return task
        }
        return try await task.value
    }

    // MARK: - chrome

    func chrome(for udid: String) async throws -> JSON {
        let task: Task<JSON, Error> = lock.withLock {
            if let task = chromes[udid] { return task }
            let task = Task { try await self.resolve(udid) }
            chromes[udid] = task
            return task
        }
        do {
            return try await task.value
        } catch {
            lock.withLock { if chromes[udid] == task { chromes[udid] = nil } } // retry next time
            throw error
        }
    }

    private func resolve(_ udid: String) async throws -> JSON {
        guard let typeId = try await deviceTypeIds()[udid] else { throw ChromeError("no simulator with udid \(udid)") }
        guard let bundle = try await bundlePaths()[typeId] else { throw ChromeError("no device type \(typeId)") }
        let profile = try await plist(Path.join(bundle, "Contents/Resources/profile.plist"))
        let chromeIdentifier = profile["chromeIdentifier"].flatMap { $0.isNull ? nil : $0 } ?? .string("")
        let id = JS.string(chromeIdentifier).split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        guard let dir = Self.chromeDir(id) else { throw ChromeError("no chrome bundle \(JS.string(profile["chromeIdentifier"]))") }
        let def = try await blocking { try JSON.parse(Data(contentsOf: URL(fileURLWithPath: Path.join(dir, "chrome.json")))) }
        let images = def["images"]
        let inset = images?["sizing"]
        func insetValue(_ key: String) -> Double { JS.number(inset?[key]) }

        // Screen size in points, from the device type.
        let caps = try await plist(Path.join(bundle, "Contents/Resources/capabilities.plist"))
        let dims = caps["capabilities"]?["ScreenDimensionsCapability"]
        let scaleValue = JS.number(dims?["main-screen-scale"])
        let scale = scaleValue != 0 && !scaleValue.isNaN ? scaleValue : 1
        let screenWidth = JS.number(dims?["main-screen-width"]) / scale
        let screenHeight = JS.number(dims?["main-screen-height"]) / scale
        if screenWidth == 0 || screenWidth.isNaN || screenHeight == 0 || screenHeight.isNaN {
            throw ChromeError("no screen size for \(typeId)")
        }

        // The screen tucks 1 pt under the bezel on each side: iPhone 17 Pro's
        // 402 pt screen + 2 × 18 pt sizing - 2 = 436 pt, its composite artwork width.
        let size = JSONObject([
            "width": .number(screenWidth + insetValue("leftWidth") + insetValue("rightWidth") - 2),
            "height": .number(screenHeight + insetValue("topHeight") + insetValue("bottomHeight") - 2),
        ])

        var slices = JSONObject()
        for key in Self.slices {
            let name = JS.string(images?[key])
            let page = try await pdfSize(Path.join(dir, "\(name).pdf"))
            slices[key] = .object(JSONObject([
                "url": .string("/chrome/\(id)/\(JS.encodeURIComponent(name)).png"),
                "width": .number(page.width),
                "height": .number(page.height),
            ]))
        }

        var buttons: [JSON] = []
        for input in def["inputs"]?.arrayValue ?? [] {
            guard JS.same(input["type"]?.stringValue, "button"), JS.truthy(input["image"]) else { continue }
            let image = JS.string(input["image"])
            guard FileManager.default.fileExists(atPath: Path.join(dir, "\(image).pdf")) else { continue }
            let page = try await pdfSize(Path.join(dir, "\(image).pdf"))
            let offsets = input["offsets"]
            let normal = offsets?["normal"]
            let imageDown = input["imageDown"].flatMap { $0.isNull ? nil : $0 }.map(JS.string) ?? image
            buttons.append(.object(JSONObject([
                "name": input["name"],
                "anchor": input["anchor"],
                "align": input["align"],
                "onTop": .bool(JS.truthy(input["onTop"])),
                "size": .object(JSONObject(["width": .number(page.width), "height": .number(page.height)])),
                "normal": normal,
                "rollover": offsets?["rollover"].flatMap { $0.isNull ? nil : $0 } ?? normal,
                "image": .string("/chrome/\(id)/\(JS.encodeURIComponent(image)).png"),
                "imageDown": .string("/chrome/\(id)/\(JS.encodeURIComponent(imageDown)).png"),
            ])))
        }

        let maskName = profile["framebufferMask"]
        let hasMask = JS.truthy(maskName)
            && FileManager.default.fileExists(atPath: Path.join(bundle, "Contents/Resources/\(JS.string(maskName)).pdf"))
        let cornerRadius = def["paths"]?["simpleOutsideBorder"]?["cornerRadiusX"].flatMap { $0.isNull ? nil : $0 }
        return .object(JSONObject([
            "id": .string(id),
            "size": .object(size),
            "screen": .object(JSONObject([
                "x": .number(insetValue("leftWidth") - 1),
                "y": .number(insetValue("topHeight") - 1),
                "width": .number(screenWidth),
                "height": .number(screenHeight),
            ])),
            "cornerRadius": cornerRadius ?? .number(0),
            "slices": .object(slices),
            "mask": hasMask ? .string("/api/sims/\(udid)/mask.png") : .null,
            "buttons": .array(buttons),
        ]))
    }

    private static func chromeDir(_ id: String) -> String? {
        guard !id.isEmpty, id.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) }) else { return nil }
        let dir = Path.join(root, "\(id).devicechrome", "Contents/Resources")
        return FileManager.default.fileExists(atPath: dir) ? dir : nil
    }

    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { byte in
            switch byte {
            case 48...57, 65...90, 97...122, UInt8(ascii: " "), UInt8(ascii: "_"), UInt8(ascii: "-"): true
            default: false
            }
        }
    }

    // MARK: - images

    /// One chrome PDF as a cached PNG at 3×. `name` must be a PDF in the bundle.
    func chromeImage(id: String, name: String) async throws -> String? {
        guard let dir = Self.chromeDir(id), Self.safeName(name) else { return nil }
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        guard listing.contains(where: { JS.same($0, "\(name).pdf") }) else { return nil }
        let out = Path.join(cache, id, "\(name)@\(Int(Self.scale))x.png")
        if !FileManager.default.fileExists(atPath: out) {
            let pdf = Path.join(dir, "\(name).pdf")
            let page = try await pdfSize(pdf)
            let longest = Int(JS.round(Double(max(page.width, page.height)) * Self.scale))
            try await blocking { try Self.rasterize(pdf, to: out, longest: longest) }
        }
        return out
    }

    /// The screen's framebuffer mask. It is already at device pixels, so 1×
    /// of its page size is native resolution.
    func maskImage(udid: String) async throws -> String? {
        guard let typeId = try await deviceTypeIds()[udid], let bundle = try await bundlePaths()[typeId] else { return nil }
        let profile = try await plist(Path.join(bundle, "Contents/Resources/profile.plist"))
        let name = JS.string(profile["framebufferMask"].flatMap { $0.isNull ? nil : $0 } ?? .string(""))
        let dir = Path.join(bundle, "Contents/Resources")
        guard Self.safeName(name), FileManager.default.fileExists(atPath: Path.join(dir, "\(name).pdf")) else { return nil }
        let out = Path.join(cache, "masks", "\(name).png")
        if !FileManager.default.fileExists(atPath: out) {
            try await blocking { try Self.rasterize(Path.join(dir, "\(name).pdf"), to: out, longest: nil) }
        }
        return out
    }

    // MARK: - CoreGraphics

    private static func pdfPage(_ path: String) throws -> CGPDFPage {
        guard let document = CGPDFDocument(URL(fileURLWithPath: path) as CFURL), let page = document.page(at: 1) else {
            throw ChromeError("could not read PDF \(path)")
        }
        return page
    }

    /// Renders page 1 on a transparent background, scaled so its longest side
    /// is `longest` pixels (or at 1 pixel per point), and writes a PNG.
    private static func rasterize(_ pdf: String, to out: String, longest: Int?) throws {
        let page = try pdfPage(pdf)
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { throw ChromeError("empty PDF page \(pdf)") }
        let factor = longest.map { Double($0) / Double(max(box.width, box.height)) } ?? 1
        let width = max(1, Int((Double(box.width) * factor).rounded()))
        let height = max(1, Int((Double(box.height) * factor).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw ChromeError("could not create a bitmap for \(pdf)") }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw ChromeError("could not render \(pdf)") }

        try FileManager.default.createDirectory(atPath: (out as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // Write beside, then rename, so a concurrent request never reads half a file.
        let tmp = "\(out).\(UUID().uuidString).tmp"
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: tmp) as CFURL, "public.png" as CFString, 1, nil) else {
            throw ChromeError("could not write \(out)")
        }
        let properties = [kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination), rename(tmp, out) == 0 else {
            unlink(tmp)
            throw ChromeError("could not write \(out)")
        }
    }

    private static func readPlist(_ path: String) throws -> JSON {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ChromeError("\(path): file does not exist or is not readable or is not a regular file")
        }
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return json(fromPlist: object)
    }

    private static func json(fromPlist value: Any) -> JSON {
        switch value {
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(array.map(json(fromPlist:)))
        case let dictionary as [String: Any]:
            var object = JSONObject()
            for key in dictionary.keys.sorted() { object[key] = json(fromPlist: dictionary[key]!) }
            return .object(object)
        case let date as Date:
            return .string(Store.timestamp(date))
        case let data as Data:
            return .string(data.base64EncodedString())
        default:
            return .null
        }
    }
}

struct ChromeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Runs blocking work (subprocesses, file and PDF reads) off Swift's
/// cooperative thread pool.
func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try body() })
        }
    }
}

/// Runs a command and returns its stdout; throws its stderr when it fails.
func run(_ command: [String]) throws -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = command
    let stdout = Pipe(), stderr = Pipe()
    task.standardOutput = stdout
    task.standardError = stderr
    task.standardInput = FileHandle.nullDevice
    try task.run()
    // Drain stderr concurrently so neither pipe can fill up and stall the child.
    nonisolated(unsafe) var errorData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    let out = stdout.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    task.waitUntilExit()
    if task.terminationStatus != 0 {
        let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw ChromeError(message.isEmpty ? "\(command[0]) exited \(task.terminationStatus)" : message)
    }
    return String(decoding: out, as: UTF8.self)
}
