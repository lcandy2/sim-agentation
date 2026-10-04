// Adapted from sim-use (https://github.com/lycorp-jp/sim-use),
// Sources/iOSSimBackend/A11y/AccessibilityFetcher.swift at cd6caf9,
// Copyright 2026 LY Corporation, licensed under the Apache License 2.0
// (see LICENSE-sim-use). Changes:
// - Nodes are our JSON dictionaries (`role`, `label`, `frame`, `children`)
//   instead of idb's (`AXLabel`, `AXFrame`); the identity key formats the
//   frame itself rather than reading idb's `AXFrame` string.
// - The probe is synchronous, and a wall-clock deadline stops probing in
//   addition to the probe budget.
// - Logging and perf counters are dropped.
// - A root with no children at all is probed as a phase-1 container
//   whatever its role (sim-use's tree source never returns that shape).
// The quadtree, budgets, caps, thresholds and blind-zone maths are unchanged.

import CoreGraphics
import Foundation

public enum CollapsedChildrenRecovery {
    /// Resolves the accessibility element at a given screen point. Returning
    /// `nil` causes that sample point to be skipped.
    public typealias PointProbe = (CGPoint) -> [String: Any]?

    // Eligibility gate for phase 1.
    public static let minContainerWidth: Double = 100
    public static let minContainerHeight: Double = 30

    // Quadtree refinement parameters. Seed cells are rectangular (wider than
    // tall) to match the typical UI element aspect ratio: nav links,
    // headlines, cells and text rows are almost always landscape.
    public static let defaultSeedCellWidth: Double = 160
    public static let defaultSeedCellHeight: Double = 80
    public static let coverageTerminationRatio: Double = 0.95

    // Phase 2 thresholds. A gap rectangle between siblings must clear both
    // `minBlindZoneMinDim` on each side and `minBlindZoneArea` in total to
    // qualify: enough to host a plausible accessibility element rather than
    // inter-element padding.
    public static let minBlindZoneMinDim: Double = 60
    public static let minBlindZoneArea: Double = 10_000

    public static let defaultMaxProbes: Int = 300
    public static let defaultMinCellSize: Double = 14

    public static func recover(
        in root: [String: Any],
        probe: PointProbe,
        deadline: Date,
        maxProbes: Int = defaultMaxProbes,
        minCellSize: Double = defaultMinCellSize,
        seedCellWidth: Double = defaultSeedCellWidth,
        seedCellHeight: Double = defaultSeedCellHeight,
        scanBlindZones: Bool = true
    ) -> (tree: [String: Any], probes: Int) {
        let budget = ProbeBudget(maxProbes, deadline: deadline)
        let tuning = Tuning(
            minCellSize: max(1, minCellSize),
            seedCellWidth: max(1, seedCellWidth),
            seedCellHeight: max(1, seedCellHeight)
        )
        // Traversal-scoped identity set, pre-seeded with every original-tree
        // node so a probe hit that collides with a natively exposed element
        // is dropped, and shared across every runProbes call so sibling
        // AXGroup wrappers do not each synthesize their own copy of the same
        // on-screen element.
        let seen = SeenIdentitySet()
        prepopulateSeen(seen, from: root)
        let tree = walk(node: root, probe: probe, budget: budget, tuning: tuning, seen: seen, scanBlindZones: scanBlindZones, isRoot: true)
        return (tree, maxProbes - budget.remaining)
    }

    /// Identity key for cross-parent dedup of synthesized hits. Returns `nil`
    /// for nodes without a usable frame (missing or zero-sized).
    public static func identityKey(for node: [String: Any]) -> String? {
        guard let f = frameTuple(of: node), f.width > 0, f.height > 0 else { return nil }
        let frameStr = "{{\(f.x), \(f.y)}, {\(f.width), \(f.height)}}"
        let role = (node["role"] as? String) ?? ""
        let label = (node["label"] as? String) ?? ""
        return "\(frameStr)|\(role)|\(label)"
    }

    private static func prepopulateSeen(_ seen: SeenIdentitySet, from node: [String: Any]) {
        if let key = identityKey(for: node) {
            seen.insert(key)
        }
        if let kids = node["children"] as? [[String: Any]] {
            for child in kids {
                prepopulateSeen(seen, from: child)
            }
        }
    }

    public struct Tuning {
        public let minCellSize: Double
        public let seedCellWidth: Double
        public let seedCellHeight: Double
        public var minRemainderArea: Double { minCellSize * minCellSize }
        /// Cap on how many times a nil probe may trigger quadrant refinement
        /// within a single `runProbes` call. The uncapped cascade
        /// (1 → 4 → 16 → 64) multiplies budget pressure on genuinely empty
        /// space while rarely uncovering a hidden element.
        public let phase1NilRefineCap: Int = 16
        public let phase2NilRefineCap: Int = 6
    }

    private static func walk(
        node: [String: Any],
        probe: PointProbe,
        budget: ProbeBudget,
        tuning: Tuning,
        seen: SeenIdentitySet,
        scanBlindZones: Bool,
        isRoot: Bool = false
    ) -> [String: Any] {
        var node = node

        let existing = (node["children"] as? [[String: Any]]) ?? []
        var children: [[String: Any]] = []
        children.reserveCapacity(existing.count)
        for child in existing {
            children.append(walk(node: child, probe: probe, budget: budget, tuning: tuning, seen: seen, scanBlindZones: scanBlindZones))
        }

        // Phase 1 — probe empty AXGroups (and an empty root).
        if children.isEmpty, shouldProbe(node) || (isRoot && rect(of: node) != nil) {
            let synthesized = runProbes(
                parent: node, seedRegions: nil, existingChildren: [],
                probe: probe, budget: budget, tuning: tuning, seen: seen
            )
            for probed in synthesized {
                children.append(walk(node: probed, probe: probe, budget: budget, tuning: tuning, seen: seen, scanBlindZones: scanBlindZones))
            }
        }

        // Phase 2 — probe significant blind zones between siblings.
        if scanBlindZones,
           !children.isEmpty,
           let region = rect(of: node),
           region.width >= minContainerWidth,
           region.height >= minContainerHeight {
            let childFrames = children.compactMap { rect(of: $0) }
            let blindZones = computeBlindZones(in: region, coveredBy: childFrames)
                .filter { zone in
                    min(zone.width, zone.height) >= CGFloat(minBlindZoneMinDim)
                        && zone.width * zone.height >= CGFloat(minBlindZoneArea)
                }
            if !blindZones.isEmpty {
                let discovered = runProbes(
                    parent: node, seedRegions: blindZones, existingChildren: children,
                    probe: probe, budget: budget, tuning: tuning, seen: seen
                )
                for probed in discovered {
                    children.append(walk(node: probed, probe: probe, budget: budget, tuning: tuning, seen: seen, scanBlindZones: scanBlindZones))
                }
            }
        }

        node["children"] = children
        return node
    }

    public static func shouldProbe(_ node: [String: Any]) -> Bool {
        // Only AXGroup containers — the shape AXPTranslator collapses.
        guard (node["role"] as? String) == "AXGroup" else { return false }
        // Skip anything we synthesized ourselves to avoid re-probing the same frame.
        if (node["synthesized"] as? Bool) == true { return false }
        guard let f = frameTuple(of: node),
              f.width >= minContainerWidth,
              f.height >= minContainerHeight else {
            return false
        }
        return true
    }

    /// Core quadtree orchestrator. Phase 1 passes `seedRegions == nil` and
    /// `existingChildren == []` so the entire parent frame is seeded. Phase 2
    /// passes the blind-zone rectangles and the parent's direct children so
    /// their frames pre-populate the covered set.
    private static func runProbes(
        parent: [String: Any],
        seedRegions: [CGRect]?,
        existingChildren: [[String: Any]],
        probe: PointProbe,
        budget: ProbeBudget,
        tuning: Tuning,
        seen: SeenIdentitySet
    ) -> [[String: Any]] {
        guard let region = rect(of: parent) else { return [] }
        let parentKey = identityKey(for: parent)
        let slack: CGFloat = 1.0
        let regionArea = region.width * region.height
        let coverageTarget = regionArea * CGFloat(coverageTerminationRatio)

        var queue = WorkQueue()
        let childFrames: [CGRect] = existingChildren.compactMap { rect(of: $0) }
        var covered: [CGRect] = childFrames
        var hits: [[String: Any]] = []
        var coveredArea: CGFloat = 0
        var nilRefineCount = 0

        // Seed cells, intersected with the region so cells never straddle
        // the container boundary.
        let cellW = CGFloat(tuning.seedCellWidth)
        let cellH = CGFloat(tuning.seedCellHeight)
        let regions = seedRegions ?? [region]
        for seed in regions {
            let clipped = seed.intersection(region)
            if clipped.isNull || clipped.isEmpty { continue }
            let cols = max(1, Int((clipped.width / cellW).rounded(.up)))
            let rows = max(1, Int((clipped.height / cellH).rounded(.up)))
            for row in 0..<rows {
                for col in 0..<cols {
                    let x = clipped.minX + CGFloat(col) * cellW
                    let y = clipped.minY + CGFloat(row) * cellH
                    let w = min(cellW, clipped.maxX - x)
                    let h = min(cellH, clipped.maxY - y)
                    if w <= 0 || h <= 0 { continue }
                    queue.push(CGRect(x: x, y: y, width: w, height: h))
                }
            }
        }

        let touchTargetSlop: CGFloat = 2

        drain: while let cell = queue.pop(), budget.available {
            let centre = CGPoint(x: cell.midX, y: cell.midY)

            if covered.contains(where: { $0.insetBy(dx: -touchTargetSlop, dy: -touchTargetSlop).contains(centre) }) {
                continue
            }

            budget.consume()

            guard let hit = probe(centre) else {
                // Nil-refine is capped per phase: phase 1 looser (small
                // AXGroup containers may hide a single tight element), phase
                // 2 tighter (the blind zone is usually either populated or
                // really empty).
                let cap = seedRegions == nil ? tuning.phase1NilRefineCap : tuning.phase2NilRefineCap
                if nilRefineCount < cap, min(cell.width, cell.height) > CGFloat(tuning.minCellSize) {
                    for quadrant in splitQuadrants(cell) { queue.push(quadrant) }
                    nilRefineCount += 1
                }
                continue
            }

            if let parentKey, identityKey(for: hit).map({ $0.components(separatedBy: "|")[0] }) == parentKey.components(separatedBy: "|")[0] {
                continue // the probe hit the parent itself
            }

            guard let hitRect = rect(of: hit) else { continue }

            if !rectContained(hitRect, in: region, slack: slack) { continue }

            // Phase 2 dedup: a hit inside any existing direct-child frame is
            // already represented by a descendant of that child.
            if childFrames.contains(where: { rectContained(hitRect, in: $0, slack: slack) }) { continue }

            // Nil key → zero/missing-frame hit: bypass identity dedup.
            if let key = identityKey(for: hit) {
                if seen.contains(key) { continue }
                seen.insert(key)
            }
            var marked = hit
            marked["synthesized"] = true
            hits.append(marked)
            covered.append(hitRect)

            let clipped = hitRect.intersection(region)
            if !clipped.isNull {
                coveredArea += clipped.width * clipped.height
                if coveredArea >= coverageTarget { break drain }
            }

            // Opportunistic remainder subdivide: everything the hit did not
            // occupy becomes a candidate for further sampling so thin
            // neighbours stay reachable through the refinement chain.
            for remainder in subtract(hitRect, from: cell)
            where remainder.width * remainder.height > CGFloat(tuning.minRemainderArea) {
                queue.push(remainder)
            }
        }
        return hits
    }

    // MARK: - Geometry helpers

    private static func rectContained(_ inner: CGRect, in outer: CGRect, slack: CGFloat) -> Bool {
        if inner.minX + slack < outer.minX { return false }
        if inner.maxX > outer.maxX + slack { return false }
        if inner.minY + slack < outer.minY { return false }
        if inner.maxY > outer.maxY + slack { return false }
        return true
    }

    private static func splitQuadrants(_ cell: CGRect) -> [CGRect] {
        let halfW = cell.width / 2
        let halfH = cell.height / 2
        return [
            CGRect(x: cell.minX, y: cell.minY, width: halfW, height: halfH),
            CGRect(x: cell.minX + halfW, y: cell.minY, width: halfW, height: halfH),
            CGRect(x: cell.minX, y: cell.minY + halfH, width: halfW, height: halfH),
            CGRect(x: cell.minX + halfW, y: cell.minY + halfH, width: halfW, height: halfH),
        ]
    }

    // Classic 4-strip rectangle subtraction: `cell` minus the portion of
    // `hit` that overlaps it.
    private static func subtract(_ hit: CGRect, from cell: CGRect) -> [CGRect] {
        let ix = cell.intersection(hit)
        if ix.isNull || ix.isEmpty { return [] }
        var strips: [CGRect] = []
        if ix.minY > cell.minY {
            strips.append(CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: ix.minY - cell.minY))
        }
        if ix.maxY < cell.maxY {
            strips.append(CGRect(x: cell.minX, y: ix.maxY, width: cell.width, height: cell.maxY - ix.maxY))
        }
        if ix.minX > cell.minX {
            strips.append(CGRect(x: cell.minX, y: ix.minY, width: ix.minX - cell.minX, height: ix.height))
        }
        if ix.maxX < cell.maxX {
            strips.append(CGRect(x: ix.maxX, y: ix.minY, width: cell.maxX - ix.maxX, height: ix.height))
        }
        return strips
    }

    /// Horizontal-strip decomposition of `region \ ⋃ covers`, with vertically
    /// adjacent strips that share the same x-span merged into tall rectangles.
    public static func computeBlindZones(in region: CGRect, coveredBy covers: [CGRect]) -> [CGRect] {
        guard region.width > 0, region.height > 0 else { return [] }

        let clipped: [CGRect] = covers.compactMap { r in
            let ix = r.intersection(region)
            return (ix.isNull || ix.isEmpty) ? nil : ix
        }
        if clipped.isEmpty { return [region] }

        var ys: Set<CGFloat> = [region.minY, region.maxY]
        for r in clipped {
            ys.insert(r.minY)
            ys.insert(r.maxY)
        }
        let sortedYs = ys.sorted()

        var zones: [CGRect] = []
        for i in 0..<(sortedYs.count - 1) {
            let yTop = sortedYs[i]
            let yBot = sortedYs[i + 1]
            let stripHeight = yBot - yTop
            if stripHeight <= 0 { continue }

            var intervals: [(x0: CGFloat, x1: CGFloat)] = []
            for r in clipped where r.minY < yBot && r.maxY > yTop {
                intervals.append((r.minX, r.maxX))
            }
            intervals.sort { $0.x0 < $1.x0 }

            var merged: [(x0: CGFloat, x1: CGFloat)] = []
            for iv in intervals {
                if !merged.isEmpty, merged[merged.count - 1].x1 >= iv.x0 {
                    merged[merged.count - 1].x1 = max(merged[merged.count - 1].x1, iv.x1)
                } else {
                    merged.append(iv)
                }
            }

            var x = region.minX
            for iv in merged {
                if iv.x0 > x {
                    zones.append(CGRect(x: x, y: yTop, width: iv.x0 - x, height: stripHeight))
                }
                x = max(x, iv.x1)
            }
            if x < region.maxX {
                zones.append(CGRect(x: x, y: yTop, width: region.maxX - x, height: stripHeight))
            }
        }

        zones.sort { lhs, rhs in
            if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
            return lhs.minY < rhs.minY
        }
        var mergedZones: [CGRect] = []
        let tol: CGFloat = 0.001
        for z in zones {
            if let last = mergedZones.last,
               abs(last.minX - z.minX) < tol,
               abs(last.width - z.width) < tol,
               abs(last.maxY - z.minY) < tol {
                mergedZones[mergedZones.count - 1] = CGRect(x: last.minX, y: last.minY, width: last.width, height: last.height + z.height)
            } else {
                mergedZones.append(z)
            }
        }
        return mergedZones
    }

    private static func frameTuple(of node: [String: Any]) -> (x: Double, y: Double, width: Double, height: Double)? {
        guard let f = node["frame"] as? [String: Any] else { return nil }
        func readNumber(_ v: Any?) -> Double? {
            if let d = v as? Double { return d }
            if let n = v as? NSNumber { return n.doubleValue }
            return nil
        }
        guard let x = readNumber(f["x"]), let y = readNumber(f["y"]),
              let width = readNumber(f["width"]), let height = readNumber(f["height"]) else { return nil }
        return (x, y, width, height)
    }

    private static func rect(of node: [String: Any]) -> CGRect? {
        guard let f = frameTuple(of: node) else { return nil }
        return CGRect(x: f.x, y: f.y, width: f.width, height: f.height)
    }
}

/// Shared probe counter threaded through every probe in one `recover` call,
/// so phase 1 and phase 2 drain the same budget. Also stops at `deadline`.
private final class ProbeBudget {
    private(set) var remaining: Int
    private let deadline: Date

    init(_ budget: Int, deadline: Date) {
        remaining = max(0, budget)
        self.deadline = deadline
    }

    var available: Bool { remaining > 0 && Date() < deadline }

    func consume() {
        if remaining > 0 { remaining -= 1 }
    }
}

/// Traversal-scoped dedup for synthesized probe hits.
private final class SeenIdentitySet {
    private var keys: Set<String> = []
    func insert(_ key: String) { keys.insert(key) }
    func contains(_ key: String) -> Bool { keys.contains(key) }
}

/// Max-heap by rectangle area (sorted array; popping takes the largest). On
/// ties the oldest insertion pops first.
private struct WorkQueue {
    private var items: [(rect: CGRect, area: CGFloat)] = []

    mutating func push(_ rect: CGRect) {
        let area = rect.width * rect.height
        if area <= 0 { return }
        let idx = items.firstIndex(where: { $0.area >= area }) ?? items.endIndex
        items.insert((rect, area), at: idx)
    }

    mutating func pop() -> CGRect? {
        items.popLast()?.rect
    }
}
