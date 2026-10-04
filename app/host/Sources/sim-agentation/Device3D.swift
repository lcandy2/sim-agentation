import CoreGraphics
import Foundation
import IOSurface
import Metal
import MetalPerformanceShaders
import RealityKit

// iPhone Duo drawn as Device Hub draws it: Apple's own model of the device
// (V68.usdz, inside Xcode's DeviceKit), posed by the hinge, with each
// panel's frames on its screen, rendered on this Mac with RealityKit and
// streamed like any frame. Ported from baguette's RealityKitDeviceScene,
// FoldPose, InterfaceRoll, FoldedScreenProjection, ScreenQuadProjection,
// DeviceCameraFraming, DeviceStudioLighting and MetalRenderTargetRing, and
// its iphone-duo definition (https://github.com/tddworks/baguette, Apache
// License 2.0); changes: the Duo alone (no variants, cover glass, gyro or
// phone models), the lit panel and the device's turn from `Foldable`, the
// render size changing in place, and the camera framing the book as it's
// posed (closer as it shuts, farther as it opens) rather than the flat book.

/// The model, as baguette's `Models3D/iphone-duo/definition.json` names it.
private enum Duo {
    static let asset = "SharedFrameworks/DeviceKit.framework/Versions/A/PlugIns/CoreDevicePopDeviceKitExtension.devicekitplugin/Contents/Resources/V68.usdz"
    static let rootNode = "root"
    static let screenMaterial = "CvyXbAGXoolRUYl"
    static let coverMaterial = "YqugYDOqMSOpqyA"
    /// The unfolded framebuffer's rows run the other way from the mesh's UVs.
    static let textureRotation = 270
    /// Authored lying flat, screen up: stood up to face the camera.
    static let restRotation = (x: 90.0, y: 0.0, z: 0.0)
    /// The clip that shuts the book: flat at 0 s, shut at `shutTime`.
    static let clip = "l_over_r"
    static let shutTime = 5.0
    /// Device Hub's open pose, from where up the bend is centred.
    static let openPoseDegrees = 130.0
    /// The wire names of the keys, and the skeleton joints that sit on them.
    static let buttons = [
        (id: "power", joint: "oknVLIOxyFKJJzk"),
        (id: "action", joint: "mblzAmIUcCyEAJi"),
        (id: "volume-up", joint: "xsdEUgktlZKTjeM"),
        (id: "volume-down", joint: "oRVcvMIHfnBuWqp"),
    ]

    /// V68.usdz in the selected Xcode, else the newest that has it (the
    /// Duo needs Xcode 27.1, which needn't be the one selected).
    /// Looked up once (it asks xcode-select): a new Xcode needs a new host.
    static func assetURL() -> URL? { found }
    private static let found: URL? = {
        var roots: [String] = []
        if let developer = try? run(["xcode-select", "-p"]).trimmingCharacters(in: .whitespacesAndNewlines) {
            roots.append(URL(fileURLWithPath: developer).deletingLastPathComponent().path) // …/Contents
        }
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        roots += apps.filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }.sorted(by: >).map { "/Applications/\($0)/Contents" }
        return roots.lazy.map { URL(fileURLWithPath: Path.join($0, asset)) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }()
}

// MARK: - pose and projection (plain math)

struct Vector3 {
    var x: Double, y: Double, z: Double

    func rotatedX(_ degrees: Double) -> Vector3 {
        let (c, s) = (cos(degrees * .pi / 180), sin(degrees * .pi / 180))
        return Vector3(x: x, y: y * c - z * s, z: y * s + z * c)
    }

    func rotatedY(_ degrees: Double) -> Vector3 {
        let (c, s) = (cos(degrees * .pi / 180), sin(degrees * .pi / 180))
        return Vector3(x: x * c + z * s, y: y, z: -x * s + z * c)
    }

    func rotatedZ(_ degrees: Double) -> Vector3 {
        let (c, s) = (cos(degrees * .pi / 180), sin(degrees * .pi / 180))
        return Vector3(x: x * c - y * s, y: x * s + y * c, z: z)
    }

    static func + (a: Vector3, b: Vector3) -> Vector3 { Vector3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
}

/// Degrees about world X, then Y, then Z, as `qz * qy * qx` turns a vector.
struct Rotation {
    var x = 0.0, y = 0.0, z = 0.0

    func apply(_ v: Vector3) -> Vector3 { v.rotatedX(x).rotatedY(y).rotatedZ(z) }
}

/// A screen's four corners in the model's rest frame.
struct ScreenCorners {
    var topLeft: Vector3, topRight: Vector3, bottomRight: Vector3, bottomLeft: Vector3

    /// From its bounding box: the thinnest extent is the face normal; of
    /// the other two, y is up unless y is the thin one.
    static func from(center: Vector3, extents: Vector3) -> ScreenCorners {
        enum Axis { case x, y, z }
        func get(_ v: Vector3, _ a: Axis) -> Double { a == .x ? v.x : a == .y ? v.y : v.z }
        func add(_ v: Vector3, _ a: Axis, _ d: Double) -> Vector3 {
            Vector3(x: v.x + (a == .x ? d : 0), y: v.y + (a == .y ? d : 0), z: v.z + (a == .z ? d : 0))
        }
        let vertical: Axis, horizontal: Axis
        if extents.y <= extents.x, extents.y <= extents.z {
            vertical = extents.z <= extents.x ? .z : .x
            horizontal = vertical == .z ? .x : .z
        } else {
            vertical = .y
            horizontal = extents.x <= extents.z ? .z : .x
        }
        let halfHeight = get(extents, vertical) / 2, halfWidth = get(extents, horizontal) / 2
        func corner(left: Bool, top: Bool) -> Vector3 {
            add(add(center, horizontal, left ? -halfWidth : halfWidth), vertical, top ? halfHeight : -halfHeight)
        }
        return ScreenCorners(
            topLeft: corner(left: true, top: true), topRight: corner(left: false, top: true),
            bottomRight: corner(left: false, top: false), bottomLeft: corner(left: true, top: false)
        )
    }
}

/// How the book is posed for a hinge angle. The shutting clip raises the
/// left half alone; Device Hub's open poses are a centred bend, so the
/// whole device turns back by half the fold to share it between the
/// halves: fully above the open pose, handing over as the book shuts so
/// the cover ends facing the camera.
struct FoldPose {
    let clipTime: Double
    /// About the hinge axis; negative turns the raised half back.
    let yawDegrees: Double

    static func at(degrees: Double) -> FoldPose {
        let angle = max(0, min(180, degrees))
        let fold = 180 - angle
        let share = max(0, min(1, angle / Duo.openPoseDegrees))
        return FoldPose(clipTime: fold / 180 * Duo.shutTime, yawDegrees: -(fold / 2) * share)
    }

    /// The sideways shift that keeps the bent screen in the middle as the
    /// book folds, as Device Hub keeps it centred in its window.
    static func centring(inner: ScreenCorners, degrees: Double) -> Vector3 {
        let pose = at(degrees: degrees)
        let raise = 180 - max(0, min(180, degrees))
        let seamTop = Vector3(x: 0, y: inner.topLeft.y, z: inner.topLeft.z)
        let seamBottom = Vector3(x: 0, y: inner.bottomLeft.y, z: inner.bottomLeft.z)
        let points = ([inner.topLeft, inner.bottomLeft].map { $0.rotatedY(raise) } + [seamTop, seamBottom, inner.topRight, inner.bottomRight])
            .map { $0.rotatedY(pose.yawDegrees) }
        let xs = points.map(\.x)
        return Vector3(x: -((xs.min() ?? 0) + (xs.max() ?? 0)) / 2, y: 0, z: 0)
    }
}

/// The perspective camera every projection here shares with the renderer:
/// on the world z axis looking down -z, a fixed vertical field of view.
struct Camera {
    static let fieldOfView = 32.0
    var distance: Double
    var aspect: Double

    /// The distance at which every point, in camera space, is in frame,
    /// filling `fill` of its width and height: a point at x, y and depth z
    /// is in frame once distance − z ≥ |x| / tan(half width) and
    /// |y| / tan(half height).
    static func distance(fitting points: [Vector3], aspect: Double, fill: (x: Double, y: Double)) -> Double {
        let tanV = tan(fieldOfView * .pi / 360), tanH = tanV * aspect
        return points.map { $0.z + max(abs($0.x) / (tanH * fill.x), abs($0.y) / (tanV * fill.y)) }.max() ?? 1
    }

    /// (0, 0) top-left of the frame, (1, 1) bottom-right.
    func project(_ v: Vector3) -> [Double] {
        let depth = distance - v.z
        let halfVertical = Self.fieldOfView * .pi / 360
        let halfHorizontal = atan(tan(halfVertical) * aspect)
        let x = v.x / (depth * tan(halfHorizontal)), y = v.y / (depth * tan(halfVertical))
        return [(x + 1) / 2, (1 - y) / 2]
    }
}

/// How a panel's framebuffer lies on its mesh, fixed by the hardware
/// (baguette's names): the unfolded one landscape-left, the cover portrait.
private enum MeshTurn { case portrait, landscapeLeft, landscapeRight, upsideDown }

/// Where the lit screen and the keys land in the rendered frame. Both
/// screens are in the rest frame: flat, facing +z, the hinge the y axis,
/// the left half at x < 0 and the cover on its back. The clip raises the
/// left half about the hinge; the centring turn and shift apply to all,
/// then the roll, then the camera. The unfolded screen bends at the hinge
/// so it's two pieces, each with its corners in the framebuffer's own
/// order and the part of the buffer it shows: the page maps a click
/// straight into buffer space, where touches land.
private struct Projection {
    let degrees: Double
    let rotation: Rotation
    let offset: Vector3
    let camera: Camera

    private var raise: Double { 180 - max(0, min(180, degrees)) }

    private func place(_ p: Vector3) -> [Double] {
        camera.project(rotation.apply(p.rotatedY(FoldPose.at(degrees: degrees).yawDegrees) + offset))
    }

    func pieces(inner: ScreenCorners, cover: ScreenCorners, unfoldedLit: Bool) -> [[String: Any]] {
        let lift = { (p: Vector3) in p.rotatedY(raise) }
        func piece(_ c: [Vector3], _ turn: MeshTurn, u: ClosedRange<Double>, v: ClosedRange<Double>) -> [String: Any] {
            // Visual corners (TL, TR, BR, BL) renamed as the buffer sees them.
            let q = c.map(place)
            let corners: [[Double]]
            switch turn {
            case .portrait: corners = q
            case .landscapeLeft: corners = [q[1], q[2], q[3], q[0]]
            case .landscapeRight: corners = [q[3], q[0], q[1], q[2]]
            case .upsideDown: corners = [q[2], q[3], q[0], q[1]]
            }
            return ["corners": corners, "u": [u.lowerBound, u.upperBound], "v": [v.lowerBound, v.upperBound]]
        }
        guard unfoldedLit else {
            // Shut, the cover has turned with the left half to face the
            // camera, mirrored: its hinge edge is now its visual left.
            return [piece([lift(cover.topRight), lift(cover.topLeft), lift(cover.bottomLeft), lift(cover.bottomRight)], .portrait, u: 0...1, v: 0...1)]
        }
        let seamTop = Vector3(x: 0, y: inner.topLeft.y, z: inner.topLeft.z)
        let seamBottom = Vector3(x: 0, y: inner.bottomLeft.y, z: inner.bottomLeft.z)
        // Landscape-left: a visual x range is the buffer's v, reversed.
        return [
            piece([lift(inner.topLeft), seamTop, seamBottom, lift(inner.bottomLeft)], .landscapeLeft, u: 0...1, v: 0.5...1),
            piece([seamTop, inner.topRight, inner.bottomRight, seamBottom], .landscapeLeft, u: 0...1, v: 0...0.5),
        ]
    }

    /// Keys on the left half turn with it as the book shuts; each control
    /// sits `margin` out past the edge its key is on, as Device Hub draws them.
    func buttons(_ anchors: [(id: String, at: Vector3)], body: Vector3, margin: Double) -> [[String: Any]] {
        anchors.map { anchor in
            let p = anchor.at
            let onSide = abs(p.x) / max(body.x / 2, 1e-9) >= abs(p.y) / max(body.y / 2, 1e-9)
            let out = onSide ? Vector3(x: p.x < 0 ? -margin : margin, y: 0, z: 0) : Vector3(x: 0, y: p.y < 0 ? -margin : margin, z: 0)
            let bend = { (q: Vector3) in p.x < 0 ? q.rotatedY(raise) : q }
            return ["id": anchor.id, "at": place(bend(p)), "control": place(bend(p + out))]
        }
    }
}

// MARK: - the scene

/// One live RealityKit stage for a stream: the model, camera and lighting
/// are made once; per frame only the screen textures and the target
/// change. RealityKit's renderer is main-actor bound, so callers go
/// through `onMain`.
@MainActor
final class DuoScene {
    private struct ScreenSlot {
        let entity: ModelEntity
        let materialIndex: Int
        var texture: LowLevelTexture?
        var size: (width: Int, height: Int)?
    }

    private let renderer: RealityRenderer
    private let wrapper: Entity
    private let rest: Entity
    private let restOrientation: simd_quatf
    private let cameraEntity: PerspectiveCamera
    private var screen: ScreenSlot
    private var cover: ScreenSlot
    private let fold: AnimationPlaybackController
    private let inner: ScreenCorners
    private let coverCorners: ScreenCorners
    private let body: Vector3
    private let anchors: [(id: String, at: Vector3)]
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private var targets: [(surface: IOSurface, texture: any MTLTexture)] = []
    private var targetIndex = 0
    private var supersampled: (texture: any MTLTexture, output: RealityRenderer.CameraOutput)?
    private let downscale: MPSImageLanczosScale
    private(set) var size: (width: Int, height: Int) = (0, 0)
    private var camera = Camera(distance: 1, aspect: 1)
    /// The distance that frames the book, and the page's zoom: the camera
    /// moves in and out, as a dolly, rather than the lens changing.
    private var framedDistance = 1.0
    private var zoom = 1.0
    /// Pixels the book stays in from each edge at 100%.
    private var margin = 0.0
    private var degrees = 0.0
    private var unfoldedLit = false
    private var turn = 0
    /// The screens skinned at the framebuffer points the page needs: the
    /// unfolded one's edges at each strip boundary across the crease, the
    /// cover's corners. Nil if the model isn't skinned as expected.
    private var innerSkin: SkinnedScreen?
    private var coverSkin: SkinnedScreen?
    private var innerSpots: [(v: Double, top: SkinnedScreen.Spot, bottom: SkinnedScreen.Spot)] = []
    private var coverSpots: [SkinnedScreen.Spot] = []
    /// Where the page is told the screen and the keys are, after the next
    /// render has posed the joints.
    private var layoutDirty = true
    var onLayout: (@MainActor ([String: Any]) -> Void)?

    /// Strips across the unfolded screen, finer where it bends (its middle):
    /// each is near enough flat for one homography.
    private static let strips: [Double] = [0, 0.1, 0.2, 0.3, 0.38, 0.43, 0.46, 0.48, 0.5, 0.52, 0.54, 0.57, 0.62, 0.7, 0.8, 0.9, 1]

    // Building one takes about a second (the model 0.5 to 0.7 s, then the
    // first render setting up the GPU 0.35 s), every time iPhone Duo is
    // opened. So a stream that ends leaves its scene here for the next, and
    // the page asking for a foldable's chrome builds one ahead, unless a
    // stream is drawing the book: building holds the main queue, where
    // every book is drawn, for that second.
    private static var spare: DuoScene?
    private static var building = false
    private static var inUse = 0

    /// A scene for a stream: the spare if there is one, laid out afresh, else a new one.
    static func make(width: Int, height: Int, background: CGColor) throws -> DuoScene {
        let scene = try spare ?? DuoScene(width: width, height: height, background: background)
        spare = nil
        scene.layoutDirty = true
        inUse += 1
        return scene
    }

    /// Keeps a scene a stream is done with for the next.
    static func park(_ scene: DuoScene) {
        scene.onLayout = nil
        spare = scene
        inUse = max(0, inUse - 1)
    }

    /// Builds the spare ahead, drawn once, on the main queue.
    nonisolated static func prepare() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard spare == nil, !building, inUse == 0 else { return }
                building = true
                defer { building = false }
                guard let scene = try? DuoScene(width: 960, height: 640, background: CGColor(red: 1, green: 1, blue: 1, alpha: 1)) else { return }
                // Drawn with screens on it: the screens' material is what
                // the GPU takes longest to set up, at the first frame.
                let blank = IOSurface(properties: [.width: 64, .height: 64, .bytesPerElement: 4, .pixelFormat: 0x4247_5241 /* BGRA */])
                _ = try? scene.render(unfolded: blank, cover: blank)
                if spare == nil { spare = scene }
            }
        }
    }

    /// Loads the model from Xcode and sets the stage for `width` × `height`.
    init(width: Int, height: Int, background: CGColor) throws {
        guard let url = Duo.assetURL() else { throw GuestError("no V68.usdz: iPhone Duo's model comes with Xcode 27.1") }
        let loaded = try Entity.load(contentsOf: url)
        guard let subject = loaded.name == Duo.rootNode ? loaded : loaded.findEntity(named: Duo.rootNode),
              let screenEntity = Self.findScreen(under: subject, material: Duo.screenMaterial),
              let coverEntity = Self.findScreen(under: subject, material: Duo.coverMaterial),
              let clip = subject.availableAnimations.first(where: { $0.name == Duo.clip && $0.definition.duration.isFinite })
        else { throw GuestError("V68.usdz isn't the model this was made for") }
        screen = ScreenSlot(entity: screenEntity, materialIndex: screenEntity.model?.materials.firstIndex { $0.name == Duo.screenMaterial } ?? 0)
        cover = ScreenSlot(entity: coverEntity, materialIndex: coverEntity.model?.materials.firstIndex { $0.name == Duo.coverMaterial } ?? 0)
        try Self.turnTextureCoordinates(of: screenEntity, materialIndex: screen.materialIndex, by: Duo.textureRotation)
        fold = subject.playAnimation(clip, transitionDuration: 0, startsPaused: true)

        renderer = try RealityRenderer()
        wrapper = Entity()
        rest = Entity()
        subject.removeFromParent()
        rest.addChild(subject)
        wrapper.addChild(rest)
        renderer.entities.append(wrapper)
        restOrientation = Self.orientation(Rotation(x: Duo.restRotation.x, y: Duo.restRotation.y, z: Duo.restRotation.z))
        rest.orientation = restOrientation

        let extents = subject.visualBounds(relativeTo: wrapper).extents
        subject.position -= subject.visualBounds(relativeTo: rest).center
        let wrapperRef = wrapper
        func corners(_ slot: ScreenSlot) -> ScreenCorners {
            let box = Self.partBounds(of: slot.entity, materialIndex: slot.materialIndex, relativeTo: wrapperRef)
                ?? slot.entity.visualBounds(relativeTo: wrapperRef)
            return ScreenCorners.from(
                center: Vector3(x: Double(box.center.x), y: Double(box.center.y), z: Double(box.center.z)),
                extents: Vector3(x: Double(box.extents.x), y: Double(box.extents.y), z: Double(box.extents.z))
            )
        }
        inner = corners(screen)
        coverCorners = corners(cover)
        body = Vector3(x: Double(extents.x), y: Double(extents.y), z: Double(extents.z))
        anchors = Duo.buttons.compactMap { button in
            Self.jointRestPosition(named: button.joint, of: screenEntity, relativeTo: wrapperRef).map { (button.id, $0) }
        }
        // Flat, the unfolded screen faces the camera (+z) and the cover away.
        innerSkin = SkinnedScreen(entity: screenEntity, materialIndex: screen.materialIndex, face: [0, 0, 1])
        coverSkin = SkinnedScreen(entity: coverEntity, materialIndex: cover.materialIndex, face: [0, 0, -1])
        if let innerSkin {
            // The unfolded framebuffer's v runs across the crease.
            innerSpots = Self.strips.map { v in (v, innerSkin.spot(x: 0, y: v), innerSkin.spot(x: 1, y: v)) }
        }
        if let coverSkin {
            coverSpots = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map { coverSkin.spot(x: $0.0, y: $0.1) }
        }

        cameraEntity = PerspectiveCamera()
        cameraEntity.camera.fieldOfViewInDegrees = Float(Camera.fieldOfView)
        cameraEntity.camera.near = 0.01
        cameraEntity.camera.far = 10_000
        renderer.entities.append(cameraEntity)
        renderer.activeCamera = cameraEntity
        renderer.cameraSettings.antialiasing = .multisample4X
        renderer.cameraSettings.colorBackground = .color(background)
        renderer.lighting.resource = try EnvironmentResource(equirectangular: Self.studio)
        renderer.lighting.intensityExponent = 1.5 // calibrated by baguette against Quick Look

        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw GuestError("no Metal device")
        }
        self.device = device
        self.queue = queue
        downscale = MPSImageLanczosScale(device: device)
        try resize(width: width, height: height)
        pose(degrees: 0, unfoldedLit: false, turn: 0)
    }

    /// 1 frames the book as it's posed; 2 is the camera halfway in.
    func setZoom(_ zoom: Double) {
        layoutDirty = true
        self.zoom = max(0.25, min(8, zoom))
        camera.distance = framedDistance / self.zoom
        cameraEntity.position = [0, 0, Float(camera.distance)]
    }

    /// How far in from each edge the book stays at 100%, in pixels of the
    /// frame (the page fades the frame's edges, and the keys go beside it).
    func setMargin(_ pixels: Double) {
        guard pixels != margin else { return }
        margin = pixels
        frame()
    }

    /// Frames the book as it's posed now, as large as `margin` lets it be:
    /// a shut book is half as wide as an open one, so the camera comes in
    /// as it shuts and backs off as it opens, and turns with the device.
    private func frame() {
        let pose = FoldPose.at(degrees: degrees)
        let raise = 180 - max(0, min(180, degrees))
        let offset = FoldPose.centring(inner: inner, degrees: degrees)
        // The body's box split at the hinge, the left half raised by the clip.
        let (hx, hy, hz) = (body.x / 2, body.y / 2, body.z / 2)
        var points: [Vector3] = []
        for x in [-hx, 0, hx] {
            for y in [-hy, hy] {
                for z in [-hz, hz] {
                    let p = Vector3(x: x, y: y, z: z)
                    points.append(x < 0 ? p.rotatedY(raise) : p)
                }
            }
        }
        let placed = points.map { rotation.apply($0.rotatedY(pose.yawDegrees) + offset) }
        let fill = (
            x: max(0.5, 1 - 2 * margin / Double(max(size.width, 1))),
            y: max(0.5, 1 - 2 * margin / Double(max(size.height, 1)))
        )
        framedDistance = Camera.distance(fitting: placed, aspect: camera.aspect, fill: fill)
        setZoom(zoom)
    }

    /// The color behind the book (frames have no transparency).
    func setBackground(_ color: CGColor) {
        renderer.cameraSettings.colorBackground = .color(color)
    }

    /// A new frame size: the camera refits and the targets are remade.
    func resize(width: Int, height: Int) throws {
        guard (width, height) != size else { return }
        size = (width, height)
        layoutDirty = true
        camera.aspect = Double(width) / Double(height)
        frame()
        let bytesPerRow = ((width * 4 + 63) / 64) * 64
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        // Three, so the GPU and the encoder never share one.
        targets = try (0..<3).map { _ in
            guard let surface = IOSurfaceCreate([
                kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
                kIOSurfaceBytesPerRow: bytesPerRow, kIOSurfaceAllocSize: bytesPerRow * height,
                kIOSurfacePixelFormat: UInt32(0x4247_5241), // 'BGRA'
            ] as CFDictionary), let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
            else { throw GuestError("no render target \(width) × \(height)") }
            return (surface, texture)
        }
        // RealityKit's MSAA skips the unlit screen pass, whose edge then
        // stair-steps on a tilt: rendering at 2× and Lanczos-downscaling
        // smooths every pass.
        supersampled = nil
        if max(width, height) * 2 <= 4096 {
            let big = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width * 2, height: height * 2, mipmapped: false)
            big.storageMode = .private
            big.usage = [.renderTarget, .shaderRead]
            if let texture = device.makeTexture(descriptor: big) {
                supersampled = (texture, try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture)))
            }
        }
    }

    /// Poses the book at the hinge's angle (the clip at its time, the
    /// whole turned back and shifted to centre the bend) and stands it the
    /// way the device is turned: one quarter turn clockwise per step.
    func pose(degrees: Double, unfoldedLit: Bool, turn: Int) {
        layoutDirty = true
        self.degrees = degrees
        self.unfoldedLit = unfoldedLit
        self.turn = ((turn % 4) + 4) % 4
        let pose = FoldPose.at(degrees: degrees)
        fold.time = pose.clipTime
        fold.pause()
        rest.orientation = simd_quatf(angle: Float(pose.yawDegrees * .pi / 180), axis: [0, 1, 0]) * restOrientation
        let shift = FoldPose.centring(inner: inner, degrees: degrees)
        rest.position = [Float(shift.x), Float(shift.y), Float(shift.z)]
        wrapper.orientation = Self.orientation(rotation)
        frame()
    }

    /// Measured by baguette against Device Hub: a step of the device's
    /// turn is the body turned a quarter clockwise, a negative roll.
    private var rotation: Rotation { Rotation(z: [0, -90, 180, 90][turn]) }

    /// Where the lit screen and the keys land, for the page: the screen
    /// from the skinned mesh as the last render posed it (else baguette's
    /// sharp fold), each piece with how squarely it faces the camera.
    var layout: [String: Any] {
        let projection = Projection(degrees: degrees, rotation: rotation, offset: FoldPose.centring(inner: inner, degrees: degrees), camera: camera)
        return [
            "pieces": skinnedPieces() ?? projection.pieces(inner: inner, cover: coverCorners, unfoldedLit: unfoldedLit),
            "buttons": projection.buttons(anchors, body: body, margin: max(body.x, body.y) * 0.06),
            "width": size.width,
            "height": size.height,
            "degrees": degrees,
        ]
    }

    private func skinnedPieces() -> [[String: Any]]? {
        let eye = SIMD3<Float>(0, 0, Float(camera.distance))
        func piece(_ points: [(point: SIMD3<Float>, normal: SIMD3<Float>)], u: [Double], v: [Double]) -> [String: Any] {
            let center = points.map(\.point).reduce(.zero, +) / Float(points.count)
            let normal = normalize(points.map(\.normal).reduce(.zero, +))
            let corners = points.map { camera.project(Vector3(x: Double($0.point.x), y: Double($0.point.y), z: Double($0.point.z))) }
            return ["corners": corners, "u": u, "v": v, "facing": Double(dot(normal, normalize(eye - center)))]
        }
        if unfoldedLit {
            guard let skin = innerSkin, innerSpots.count > 1 else { return nil }
            let joints = skin.skin()
            let edges = innerSpots.map { (v: $0.v, top: skin.world($0.top, joints), bottom: skin.world($0.bottom, joints)) }
            return zip(edges, edges.dropFirst()).map { a, b in
                // Corners in the framebuffer's order: (0, v₀), (1, v₀), (1, v₁), (0, v₁).
                piece([a.top, a.bottom, b.bottom, b.top], u: [0, 1], v: [a.v, b.v])
            }
        }
        guard let skin = coverSkin, coverSpots.count == 4 else { return nil }
        let joints = skin.skin()
        return [piece(coverSpots.map { skin.world($0, joints) }, u: [0, 1], v: [0, 1])]
    }

    /// Each panel's latest frame on its screen (a dark panel's is black),
    /// rendered into the next target.
    func render(unfolded: IOSurface?, cover coverFrame: IOSurface?) throws -> IOSurface {
        if let unfolded { try paint(&screen, with: unfolded) }
        if let coverFrame { try paint(&cover, with: coverFrame) }
        let target = targets[targetIndex]
        targetIndex = (targetIndex + 1) % targets.count
        let output = try supersampled?.output ?? RealityRenderer.CameraOutput(.singleProjection(colorTexture: target.texture))
        let finished = DispatchSemaphore(value: 0)
        try renderer.updateAndRender(deltaTime: 1.0 / 60, cameraOutput: output, onComplete: { _ in finished.signal() })
        finished.wait()
        if let supersampled {
            guard let buffer = queue.makeCommandBuffer() else { throw GuestError("no Metal command buffer") }
            downscale.encode(commandBuffer: buffer, sourceTexture: supersampled.texture, destinationTexture: target.texture)
            buffer.commit()
            buffer.waitUntilCompleted()
        }
        // Publishes the GPU's write to whoever reads the surface next.
        IOSurfaceLock(target.surface, [], nil)
        IOSurfaceUnlock(target.surface, [], nil)
        // The joints are posed now: tell the page where the screen went.
        if layoutDirty {
            layoutDirty = false
            onLayout?(layout)
        }
        return target.surface
    }

    private func paint(_ slot: inout ScreenSlot, with surface: IOSurface) throws {
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        if slot.texture == nil || slot.size.map({ $0 != (width, height) }) ?? true {
            // Unlit and outside tone mapping, so a simulator pixel leaves the
            // frame as it came; a 2-pixel black border the frames never
            // cover lets the content edge fade into the mesh's edge.
            let texture = try LowLevelTexture(descriptor: .init(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, textureUsage: [.shaderRead, .shaderWrite]))
            var material = UnlitMaterial(applyPostProcessToneMap: false)
            material.color = .init(tint: .white, texture: .init(try TextureResource(from: texture)))
            if var model = slot.entity.model {
                model.materials[slot.materialIndex] = material
                slot.entity.model = model
            }
            try fillBlack(texture, width: width, height: height)
            slot.texture = texture
            slot.size = (width, height)
        }
        guard let texture = slot.texture, width > 4, height > 4 else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let source = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0),
              let buffer = queue.makeCommandBuffer()
        else { throw GuestError("couldn't read a frame") }
        let destination = texture.replace(using: buffer)
        guard let blit = buffer.makeBlitCommandEncoder() else { throw GuestError("no Metal blit") }
        blit.copy(
            from: source, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 2, y: 2, z: 0), sourceSize: MTLSize(width: width - 4, height: height - 4, depth: 1),
            to: destination, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 2, y: 2, z: 0)
        )
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    private func fillBlack(_ texture: LowLevelTexture, width: Int, height: Int) throws {
        var pixels = [UInt8](repeating: 0, count: width * 4 * height)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let black = device.makeTexture(descriptor: descriptor), let buffer = queue.makeCommandBuffer() else {
            throw GuestError("no Metal texture")
        }
        black.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
        let destination = texture.replace(using: buffer)
        guard let blit = buffer.makeBlitCommandEncoder() else { throw GuestError("no Metal blit") }
        blit.copy(from: black, to: destination)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    // MARK: - entity helpers

    private static func findScreen(under entity: Entity, material: String) -> ModelEntity? {
        if let model = entity as? ModelEntity, model.model?.materials.contains(where: { $0.name == material }) == true { return model }
        for child in entity.children {
            if let found = findScreen(under: child, material: material) { return found }
        }
        return nil
    }

    /// A skeleton joint's rest position, its rest pose accumulated up its
    /// parents, in `reference`'s frame.
    private static func jointRestPosition(named name: String, of entity: ModelEntity, relativeTo reference: Entity) -> Vector3? {
        guard let model = entity.model else { return nil }
        for skeleton in model.mesh.contents.skeletons {
            let joints = skeleton.joints
            guard let index = joints.firstIndex(where: { $0.name == name || $0.name.hasSuffix("/" + name) }) else { continue }
            var matrix = matrix_identity_float4x4
            var current: Int? = index
            while let i = current {
                matrix = joints[i].restPoseTransform.matrix * matrix
                current = joints[i].parentIndex
            }
            let world = entity.convert(position: SIMD3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z), to: reference)
            return Vector3(x: Double(world.x), y: Double(world.y), z: Double(world.z))
        }
        return nil
    }

    /// The bounds of one material's mesh parts: a model may keep every
    /// material on one entity, whose own bounds are the whole device.
    private static func partBounds(of entity: ModelEntity, materialIndex: Int, relativeTo reference: Entity) -> BoundingBox? {
        guard let model = entity.model else { return nil }
        var box: BoundingBox?
        for mesh in model.mesh.contents.models {
            for part in mesh.parts where part.materialIndex == materialIndex {
                for position in part.positions.elements {
                    let point = entity.convert(position: position, to: reference)
                    box = box.map { $0.union(BoundingBox(min: point, max: point)) } ?? BoundingBox(min: point, max: point)
                }
            }
        }
        return box
    }

    /// Turns one material's texture coordinates by quarter turns, so a
    /// framebuffer whose rows run the other way reads upright.
    private static func turnTextureCoordinates(of entity: ModelEntity, materialIndex: Int, by degrees: Int) throws {
        let turns = (((degrees / 90) % 4) + 4) % 4
        guard turns != 0, let model = entity.model else { return }
        var contents = model.mesh.contents
        contents.models = .init(contents.models.map { mesh in
            var mesh = mesh
            mesh.parts = .init(mesh.parts.map { part in
                guard part.materialIndex == materialIndex, let coordinates = part.textureCoordinates else { return part }
                var part = part
                part.textureCoordinates = .init(coordinates.elements.map { point in
                    var (u, v) = (point.x, point.y)
                    for _ in 0..<turns { (u, v) = (v, 1 - u) }
                    return SIMD2<Float>(u, v)
                })
                return part
            })
            return mesh
        })
        try model.mesh.replace(with: contents)
        entity.model = model
    }

    private static func orientation(_ r: Rotation) -> simd_quatf {
        let radians = { (d: Double) in Float(d * .pi / 180) }
        return simd_quatf(angle: radians(r.z), axis: [0, 0, 1]) * simd_quatf(angle: radians(r.y), axis: [0, 1, 0]) * simd_quatf(angle: radians(r.x), axis: [1, 0, 0])
    }

    /// baguette's neutral studio: soft grey with a row of softboxes, for
    /// reflections that neither tint nor clip the finish.
    private static let studio: CGImage = {
        let (width, height) = (1024, 512)
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let size = CGSize(width: width, height: height)
        let colors = [CGColor(gray: 0.36, alpha: 1), CGColor(gray: 0.30, alpha: 1), CGColor(gray: 0.12, alpha: 1), CGColor(gray: 0.25, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.32, 0.58, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
        let panelWidth = size.width * 0.15, panelHeight = size.height * 0.34, panelY = size.height * 0.38
        for (index, center) in [-0.02, 0.24, 0.50, 0.76, 1.02].enumerated() {
            let rect = CGRect(x: size.width * center - panelWidth / 2, y: panelY, width: panelWidth, height: panelHeight)
            let brightness: CGFloat = index == 3 ? 1 : 0.88
            let corner = panelWidth * 0.18
            context.saveGState()
            context.setShadow(offset: .zero, blur: panelWidth * 0.18, color: CGColor(gray: 1, alpha: 0.55))
            context.setFillColor(CGColor(gray: brightness, alpha: 1))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
            context.fillPath()
            context.restoreGState()
            let inner = rect.insetBy(dx: panelWidth * 0.12, dy: panelHeight * 0.14)
            context.setFillColor(CGColor(gray: min(brightness + 0.12, 1), alpha: 0.92))
            context.addPath(CGPath(roundedRect: inner, cornerWidth: corner * 0.75, cornerHeight: corner * 0.75, transform: nil))
            context.fillPath()
            let reflection = CGRect(x: rect.minX + panelWidth * 0.12, y: size.height * 0.20, width: panelWidth * 0.76, height: size.height * 0.18)
            context.saveGState()
            context.setShadow(offset: .zero, blur: panelWidth * 0.22, color: CGColor(gray: 1, alpha: 0.25))
            context.setFillColor(CGColor(gray: brightness, alpha: 0.12))
            context.fillEllipse(in: reflection)
            context.restoreGState()
        }
        return context.makeImage()!
    }()
}

/// Runs `body` on the main queue from any thread and returns its result.
func onMain<T>(_ body: @MainActor () throws -> T) throws -> T {
    nonisolated(unsafe) var outcome: Result<T, any Error>?
    if Thread.isMainThread {
        MainActor.assumeIsolated { outcome = Result { try body() } }
    } else {
        DispatchQueue.main.sync { MainActor.assumeIsolated { outcome = Result { try body() } } }
    }
    return try outcome!.get()
}
