import Foundation
import Metal
import MetalKit
import simd

// GraphMetal.swift — GPU force-directed layout + render.
//
// WHY METAL AND NOT OPENGL: OpenGL.framework is still present in the macOS SDK but has
// been deprecated since 10.14 and is frozen at 4.1 — it is a compatibility shim, not a
// target. Metal is the only current GPU API on this platform. Probed on this machine:
// Apple M5 Max, unified memory, 82 GB max buffer, MTLGPUFamily.apple9 + metal3.
//
// WHY GPU AT ALL, rather than SwiftUI Canvas: force-directed layout is O(n²) per frame in
// its honest form. The whole corpus is 117,924 events; even one big session's graph runs
// to thousands of nodes, and n² at 60 fps on the CPU stops being interactive in the low
// hundreds. The repulsion pass is the textbook case for a compute kernel — every node
// against every other, no dependencies, pure parallel. UNIFIED MEMORY is the second
// reason: node buffers are written once by the CPU and read by the GPU with no copy, so
// the upload that usually makes small graphs not worth the GPU costs nothing here.
//
// NO THIRD-PARTY DEPENDENCIES, and no .metal file either: the shader source is compiled at
// runtime with `makeLibrary(source:)`. A .metal file in SwiftPM needs a resource bundle and
// a build-tool plugin to reach a non-Xcode build, which is exactly the kind of toolchain
// coupling SPEC.md's zero-dependency rule exists to avoid. Runtime compilation costs a few
// ms once at startup and keeps `swift build` sufficient.

/// One node as the GPU sees it. `packed` layout discipline: keep this 32 bytes and
/// float4-aligned so Swift's memory layout and MSL's agree without padding surprises.
struct GPUNode {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var radius: Float
    var kind: Float      // GraphNodeKind rawValue as float — avoids an int attribute
    var pinned: Float    // 1 = excluded from integration (dragged / anchored)
    var pad: Float = 0
}

struct GPUEdge {
    var a: UInt32
    var b: UInt32
    var stiffness: Float
    var pad: Float = 0
}

/// Simulation constants, one uniform buffer, updated per frame.
struct GraphUniforms {
    var nodeCount: UInt32 = 0
    var edgeCount: UInt32 = 0
    var repulsion: Float = 900
    var springLength: Float = 46
    var damping: Float = 0.86
    var centerPull: Float = 0.012
    var dt: Float = 0.45
    var pad: Float = 0
}

/// View transform for the render pass.
struct GraphCamera {
    var scale: Float = 1
    var offset: SIMD2<Float> = .zero
    var viewport: SIMD2<Float> = .init(1, 1)
}

let graphShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Node { float2 position; float2 velocity; float radius; float kind; float pinned; float pad; };
struct Edge { uint a; uint b; float stiffness; float pad; };
struct Uniforms {
    uint nodeCount; uint edgeCount; float repulsion; float springLength;
    float damping; float centerPull; float dt; float pad;
};
struct Camera { float scale; float2 offset; float2 viewport; };

// ---- pass 1: n-body repulsion + centering. One thread per node, every node against
// every other. This is the pass that would sink a CPU implementation.
kernel void repel(device Node *nodes [[buffer(0)]],
                  constant Uniforms &u [[buffer(1)]],
                  uint gid [[thread_position_in_grid]])
{
    if (gid >= u.nodeCount) return;
    Node me = nodes[gid];
    float2 force = float2(0.0);

    for (uint i = 0; i < u.nodeCount; ++i) {
        if (i == gid) continue;
        float2 d = me.position - nodes[i].position;
        float distSq = dot(d, d) + 0.01;          // epsilon: coincident nodes must not divide by zero
        // Clamp the near field. Without this two nodes spawned on the same point launch
        // each other off-screen on frame 1 and the layout never recovers.
        distSq = max(distSq, 4.0);
        force += (d / distSq) * u.repulsion;
    }

    force -= me.position * u.centerPull;          // pull toward origin so nothing escapes
    nodes[gid].velocity = me.velocity + force * u.dt;
}

// ---- pass 2: spring attraction along edges. Serialized per edge into node velocity via
// atomics would be correct but slow; instead each edge thread applies a half-impulse to
// both ends, which converges the same way for a damped system and needs no atomics
// because the error is symmetric and bounded by the damping term.
kernel void spring(device Node *nodes [[buffer(0)]],
                   device const Edge *edges [[buffer(2)]],
                   constant Uniforms &u [[buffer(1)]],
                   uint gid [[thread_position_in_grid]])
{
    if (gid >= u.edgeCount) return;
    Edge e = edges[gid];
    if (e.a >= u.nodeCount || e.b >= u.nodeCount) return;

    float2 pa = nodes[e.a].position;
    float2 pb = nodes[e.b].position;
    float2 d = pb - pa;
    float dist = max(length(d), 0.001);
    float2 dir = d / dist;
    float displacement = dist - u.springLength;
    float2 impulse = dir * displacement * e.stiffness * u.dt * 0.5;

    nodes[e.a].velocity += impulse;
    nodes[e.b].velocity -= impulse;
}

// ---- pass 3: integrate + damp.
kernel void integrate(device Node *nodes [[buffer(0)]],
                      constant Uniforms &u [[buffer(1)]],
                      uint gid [[thread_position_in_grid]])
{
    if (gid >= u.nodeCount) return;
    if (nodes[gid].pinned > 0.5) { nodes[gid].velocity = float2(0.0); return; }
    float2 v = nodes[gid].velocity * u.damping;
    // Terminal velocity. A spike from a degenerate frame otherwise teleports a node.
    float speed = length(v);
    if (speed > 40.0) v = v / speed * 40.0;
    nodes[gid].velocity = v;
    nodes[gid].position += v * u.dt;
}

// ---- edge rendering: one line per edge, 2 vertices.
struct EdgeOut { float4 position [[position]]; float alpha; };

vertex EdgeOut edgeVertex(uint vid [[vertex_id]],
                          device const Node *nodes [[buffer(0)]],
                          device const Edge *edges [[buffer(2)]],
                          constant Camera &cam [[buffer(3)]])
{
    Edge e = edges[vid / 2];
    uint idx = (vid % 2 == 0) ? e.a : e.b;
    float2 p = nodes[idx].position * cam.scale + cam.offset;
    float2 ndc = float2(p.x / (cam.viewport.x * 0.5), p.y / (cam.viewport.y * 0.5));
    EdgeOut o;
    o.position = float4(ndc, 0.0, 1.0);
    // Spine edges (stiffness >= 1) are the chronological thread and read stronger.
    o.alpha = e.stiffness >= 1.0 ? 0.30 : 0.12;
    return o;
}

fragment float4 edgeFragment(EdgeOut in [[stage_in]]) {
    return float4(0.55, 0.62, 0.78, in.alpha);
}

// ---- node rendering: instanced quads, circle carved in the fragment shader. A quad per
// node beats real geometry here — no index buffer, no tessellation, and the disc stays
// perfectly round at any zoom because it is evaluated per fragment.
struct NodeOut { float4 position [[position]]; float2 local; float4 color; };

vertex NodeOut nodeVertex(uint vid [[vertex_id]],
                          uint iid [[instance_id]],
                          device const Node *nodes [[buffer(0)]],
                          constant Camera &cam [[buffer(3)]])
{
    float2 corner = float2((vid == 1 || vid == 2 || vid == 4) ? 1.0 : -1.0,
                           (vid == 2 || vid == 4 || vid == 5) ? 1.0 : -1.0);
    Node n = nodes[iid];
    float r = max(n.radius * cam.scale, 1.5);
    float2 p = n.position * cam.scale + cam.offset + corner * r;
    float2 ndc = float2(p.x / (cam.viewport.x * 0.5), p.y / (cam.viewport.y * 0.5));

    NodeOut o;
    o.position = float4(ndc, 0.0, 1.0);
    o.local = corner;
    // beat / tool / target / session — the same four-way split the graph model defines.
    if (n.kind < 0.5)       o.color = float4(0.36, 0.72, 1.00, 1.0);  // beat   — blue
    else if (n.kind < 1.5)  o.color = float4(1.00, 0.72, 0.30, 1.0);  // tool   — amber
    else if (n.kind < 2.5)  o.color = float4(0.55, 0.85, 0.55, 1.0);  // target — green
    else                    o.color = float4(0.90, 0.55, 0.95, 1.0);  // session— violet
    return o;
}

fragment float4 nodeFragment(NodeOut in [[stage_in]]) {
    float d = length(in.local);
    if (d > 1.0) discard_fragment();
    // Antialiased rim: fwidth gives the pixel footprint so the edge stays smooth at zoom.
    float aa = fwidth(d) * 1.5;
    float alpha = 1.0 - smoothstep(1.0 - aa, 1.0, d);
    return float4(in.color.rgb, in.color.a * alpha);
}
"""

/// Owns the Metal objects and the simulation buffers. Deliberately a plain class, not an
/// ObservableObject: it is driven by MTKView's draw callback at display rate, and pushing
/// 60 published changes a second through SwiftUI is exactly the churn that caused the
/// LazyVStack freeze documented in TODO.md.
final class GraphRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var repelPipe: MTLComputePipelineState!
    private var springPipe: MTLComputePipelineState!
    private var integratePipe: MTLComputePipelineState!
    private var edgePipe: MTLRenderPipelineState!
    private var nodePipe: MTLRenderPipelineState!

    private var nodeBuffer: MTLBuffer?
    private var edgeBuffer: MTLBuffer?
    private var uniforms = GraphUniforms()
    var camera = GraphCamera()

    /// Frames simulated so far. The layout is annealed — `dt` decays — so the graph
    /// settles instead of jittering forever, and a settled graph costs almost nothing.
    private(set) var frame = 0
    var running = true

    init?(device: MTLDevice) {
        self.device = device
        guard let q = device.makeCommandQueue() else { return nil }
        self.queue = q
        super.init()
        guard buildPipelines() else { return nil }
    }

    private func buildPipelines() -> Bool {
        do {
            let lib = try device.makeLibrary(source: graphShaderSource, options: nil)
            guard let repel = lib.makeFunction(name: "repel"),
                  let spring = lib.makeFunction(name: "spring"),
                  let integ = lib.makeFunction(name: "integrate"),
                  let ev = lib.makeFunction(name: "edgeVertex"),
                  let ef = lib.makeFunction(name: "edgeFragment"),
                  let nv = lib.makeFunction(name: "nodeVertex"),
                  let nf = lib.makeFunction(name: "nodeFragment") else { return false }

            repelPipe = try device.makeComputePipelineState(function: repel)
            springPipe = try device.makeComputePipelineState(function: spring)
            integratePipe = try device.makeComputePipelineState(function: integ)

            func renderPipe(_ v: MTLFunction, _ f: MTLFunction) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = v
                d.fragmentFunction = f
                d.colorAttachments[0].pixelFormat = .bgra8Unorm
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                d.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
                d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: d)
            }
            edgePipe = try renderPipe(ev, ef)
            nodePipe = try renderPipe(nv, nf)
            return true
        } catch {
            FileHandle.standardError.write("graph shader build failed: \(error)\n".data(using: .utf8)!)
            return false
        }
    }

    /// Upload a graph. Seeds positions on a spiral rather than randomly: a random cloud
    /// takes hundreds of frames to untangle, while a spiral is already locally ordered so
    /// the spine barely has to unwind.
    func load(_ g: SessionGraph) {
        frame = 0
        guard !g.nodes.isEmpty else { nodeBuffer = nil; edgeBuffer = nil; return }

        var nodes: [GPUNode] = []
        nodes.reserveCapacity(g.nodes.count)
        for (i, n) in g.nodes.enumerated() {
            let t = Float(i) * 0.45
            let r = 12 * sqrt(Float(i) + 1)
            nodes.append(GPUNode(
                position: SIMD2(r * cos(t), r * sin(t)),
                velocity: .zero,
                radius: 3.0 + min(Float(n.weight), 24) * 0.55,
                kind: Float(n.kind.rawValue),
                pinned: 0))
        }
        var edges: [GPUEdge] = g.edges.map {
            GPUEdge(a: UInt32($0.a), b: UInt32($0.b), stiffness: $0.spine ? 1.0 : 0.35)
        }

        nodeBuffer = device.makeBuffer(bytes: &nodes,
                                       length: MemoryLayout<GPUNode>.stride * nodes.count,
                                       options: .storageModeShared)
        edgeBuffer = edges.isEmpty ? nil
            : device.makeBuffer(bytes: &edges,
                                length: MemoryLayout<GPUEdge>.stride * edges.count,
                                options: .storageModeShared)
        uniforms.nodeCount = UInt32(nodes.count)
        uniforms.edgeCount = UInt32(edges.count)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        camera.viewport = SIMD2(Float(size.width), Float(size.height))
    }

    func draw(in view: MTKView) {
        guard let nodeBuffer,
              let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer() else { return }

        // Anneal: full step early, decaying to a crawl once the layout has settled. This
        // is what keeps a static graph from burning the GPU at 60 fps forever.
        let anneal = max(0.06, 1.0 - Float(frame) / 420.0)
        uniforms.dt = 0.45 * anneal

        if running && frame < 3000 {
            if let enc = cmd.makeComputeCommandEncoder() {
                func dispatch(_ pipe: MTLComputePipelineState, count: Int, extra: MTLBuffer?) {
                    guard count > 0 else { return }
                    enc.setComputePipelineState(pipe)
                    enc.setBuffer(nodeBuffer, offset: 0, index: 0)
                    enc.setBytes(&uniforms, length: MemoryLayout<GraphUniforms>.stride, index: 1)
                    if let extra { enc.setBuffer(extra, offset: 0, index: 2) }
                    let w = pipe.maxTotalThreadsPerThreadgroup
                    enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: min(w, count), height: 1, depth: 1))
                }
                dispatch(repelPipe, count: Int(uniforms.nodeCount), extra: nil)
                if let edgeBuffer { dispatch(springPipe, count: Int(uniforms.edgeCount), extra: edgeBuffer) }
                dispatch(integratePipe, count: Int(uniforms.nodeCount), extra: nil)
                enc.endEncoding()
            }
            frame += 1
        }

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let edgeBuffer, uniforms.edgeCount > 0 {
            enc.setRenderPipelineState(edgePipe)
            enc.setVertexBuffer(nodeBuffer, offset: 0, index: 0)
            enc.setVertexBuffer(edgeBuffer, offset: 0, index: 2)
            enc.setVertexBytes(&camera, length: MemoryLayout<GraphCamera>.stride, index: 3)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: Int(uniforms.edgeCount) * 2)
        }
        if uniforms.nodeCount > 0 {
            enc.setRenderPipelineState(nodePipe)
            enc.setVertexBuffer(nodeBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&camera, length: MemoryLayout<GraphCamera>.stride, index: 3)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: Int(uniforms.nodeCount))
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    /// Node nearest a point in view space — for click-to-inspect. Reads the shared buffer
    /// directly, which unified memory makes free.
    func hitTest(_ point: SIMD2<Float>) -> Int? {
        guard let nodeBuffer, uniforms.nodeCount > 0 else { return nil }
        let ptr = nodeBuffer.contents().bindMemory(to: GPUNode.self, capacity: Int(uniforms.nodeCount))
        var best: Int? = nil
        var bestDist = Float.greatestFiniteMagnitude
        for i in 0..<Int(uniforms.nodeCount) {
            let screen = ptr[i].position * camera.scale + camera.offset
            let d = simd_length(screen - point)
            if d < max(ptr[i].radius * camera.scale, 6), d < bestDist { bestDist = d; best = i }
        }
        return best
    }
}
