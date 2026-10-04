import Foundation
import RealityKit

/// One of the book's screens as RealityKit skins it, skinned again here,
/// on the CPU, at the points the page needs: the model's crease is a run
/// of joints that bends over a width, not a sharp fold about one axis, so
/// where a framebuffer point is drawn as the book shuts can only be had
/// from the mesh itself. Joint poses are read back after a render has
/// applied the clip (`ModelEntity.jointTransforms`).
@MainActor
struct SkinnedScreen {
    /// A point of the framebuffer on the mesh: a triangle and the
    /// barycentric weights in it (one may be negative just past the
    /// mesh's rounded corners, which extrapolates across the flat screen).
    struct Spot {
        let corners: (Int, Int, Int)
        let weights: SIMD3<Float>
    }

    let entity: ModelEntity
    private let positions: [SIMD3<Float>]
    private let influences: [[(joint: Int, weight: Float)]]
    private let uvs: [SIMD2<Float>]
    private let triangles: [(Int, Int, Int)]
    private let inverseBind: [simd_float4x4]
    private let parents: [Int?]
    /// Skeleton joint → the entity's joint (whose poses are read back).
    private let poseIndex: [Int]
    /// ±1: the mesh's winding against the screen's face, so a normal from
    /// it points out of the screen.
    private let outward: Float

    /// The parts of `entity` on `materialIndex`, whose face points `face`
    /// (world, as the entity stands now).
    init?(entity: ModelEntity, materialIndex: Int, face: SIMD3<Float>) {
        guard let model = entity.model, let skeleton = model.mesh.contents.skeletons.first else { return nil }
        var positions: [SIMD3<Float>] = [], influences: [[(Int, Float)]] = [], uvs: [SIMD2<Float>] = [], triangles: [(Int, Int, Int)] = []
        for mesh in model.mesh.contents.models {
            for part in mesh.parts where part.materialIndex == materialIndex {
                guard let coordinates = part.textureCoordinates?.elements,
                      let indices = part.triangleIndices?.elements,
                      let joints = part.jointInfluences?.influences.elements
                else { continue }
                let points = part.positions.elements
                guard coordinates.count == points.count, !points.isEmpty, joints.count % points.count == 0 else { continue }
                let base = positions.count, perVertex = joints.count / points.count
                positions += points
                uvs += coordinates
                for v in 0..<points.count {
                    influences.append((0..<perVertex).map { k in
                        let j = joints[v * perVertex + k]
                        return (j.jointIndex, j.weight)
                    }.filter { $0.1 > 0 })
                }
                for t in stride(from: 0, to: indices.count - 2, by: 3) {
                    triangles.append((base + Int(indices[t]), base + Int(indices[t + 1]), base + Int(indices[t + 2])))
                }
            }
        }
        guard !triangles.isEmpty else { return nil }
        let names = entity.jointNames
        let poseIndex = skeleton.joints.map { joint in
            names.firstIndex(of: joint.name) ?? names.firstIndex { $0.hasSuffix("/" + joint.name) || joint.name.hasSuffix("/" + $0) } ?? -1
        }
        guard !poseIndex.contains(-1) else { return nil }
        self.entity = entity
        self.positions = positions
        self.influences = influences
        self.uvs = uvs
        self.triangles = triangles
        self.inverseBind = skeleton.joints.map(\.inverseBindPoseMatrix)
        self.parents = skeleton.joints.map(\.parentIndex)
        self.poseIndex = poseIndex
        // The winding's normal at bind against the face the screen shows.
        let (a, b, c) = triangles[triangles.count / 2]
        let n = cross(positions[b] - positions[a], positions[c] - positions[a])
        outward = dot(entity.convert(direction: n, to: nil), face) < 0 ? -1 : 1
    }

    /// Where a framebuffer point (normalized, top-left origin) is on the
    /// mesh: its texture coordinate is (x, 1 − y).
    func spot(x: Double, y: Double) -> Spot {
        let p = SIMD2<Float>(Float(x), Float(1 - y))
        var best: (spot: Spot, worst: Float)?
        for (i, j, k) in triangles {
            let (a, b, c) = (uvs[i], uvs[j], uvs[k])
            let d = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
            guard abs(d) > 1e-12 else { continue }
            let w0 = ((b.y - c.y) * (p.x - c.x) + (c.x - b.x) * (p.y - c.y)) / d
            let w1 = ((c.y - a.y) * (p.x - c.x) + (a.x - c.x) * (p.y - c.y)) / d
            let w = SIMD3<Float>(w0, w1, 1 - w0 - w1)
            let worst = w.min()
            if worst >= -1e-5 { return Spot(corners: (i, j, k), weights: w) }
            if best == nil || worst > best!.worst { best = (Spot(corners: (i, j, k), weights: w), worst) }
        }
        return best!.spot
    }

    /// Each skeleton joint's skinning matrix as the entity is posed now.
    func skin() -> [simd_float4x4] {
        let poses = entity.jointTransforms
        var global = [simd_float4x4](repeating: matrix_identity_float4x4, count: parents.count)
        for i in 0..<parents.count {
            let local = poses[poseIndex[i]].matrix
            global[i] = parents[i].map { global[$0] * local } ?? local
        }
        return (0..<parents.count).map { global[$0] * inverseBind[$0] }
    }

    /// A vertex as skinned, in the entity's space.
    private func vertex(_ v: Int, _ skin: [simd_float4x4]) -> SIMD3<Float> {
        let bind = SIMD4<Float>(positions[v], 1)
        var out = SIMD4<Float>()
        for (joint, weight) in influences[v] { out += weight * (skin[joint] * bind) }
        return SIMD3(out.x, out.y, out.z) / max(out.w, 1e-6)
    }

    /// A spot as posed, in world space, and its screen's outward normal there.
    func world(_ spot: Spot, _ skin: [simd_float4x4]) -> (point: SIMD3<Float>, normal: SIMD3<Float>) {
        let (i, j, k) = spot.corners
        let (a, b, c) = (vertex(i, skin), vertex(j, skin), vertex(k, skin))
        let local = spot.weights.x * a + spot.weights.y * b + spot.weights.z * c
        let normal = entity.convert(direction: outward * cross(b - a, c - a), to: nil)
        return (entity.convert(position: local, to: nil), normal)
    }
}
