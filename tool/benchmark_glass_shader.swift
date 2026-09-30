// Headless Metal microbenchmark, invoked by verify_glass_shader.py.
// Measures the final fragment pass only, not Flutter compositing or phone heat.
import Foundation
import Metal

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    fatalError("Metal is unavailable")
}
let vertex = """
struct BenchVertex { float4 position [[position]]; float2 coord [[user(locn0)]]; };
vertex BenchVertex benchVertex(uint id [[vertex_id]], constant float2 &size [[buffer(0)]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return {float4(p.x * 2 - 1, 1 - p.y * 2, 0, 1), p * size};
}
"""
func pipeline(_ path: String) throws -> MTLRenderPipelineState {
    let source = try String(contentsOfFile: path, encoding: .utf8)
    let library = try device.makeLibrary(source: source + vertex, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "benchVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "liquid_glass_render_fragment_main")
    descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
    return try device.makeRenderPipelineState(descriptor: descriptor)
}
let pipelines = try CommandLine.arguments.dropFirst().map { try pipeline($0) }
precondition(pipelines.count == 2, "Expected reference and current MSL files")
let nearest = MTLSamplerDescriptor()
nearest.minFilter = .nearest
nearest.magFilter = .nearest
nearest.sAddressMode = .clampToEdge
nearest.tAddressMode = .clampToEdge
let nearestSampler = device.makeSamplerState(descriptor: nearest)!
let linear = nearest.copy() as! MTLSamplerDescriptor
linear.minFilter = .linear
linear.magFilter = .linear
let linearSampler = device.makeSamplerState(descriptor: linear)!

func texture(_ width: Int, _ height: Int, target: Bool = false) -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = target ? [.renderTarget, .shaderRead] : [.shaderRead]
    descriptor.storageMode = .shared
    return device.makeTexture(descriptor: descriptor)!
}
func upload(_ bytes: [UInt8], _ tex: MTLTexture) {
    bytes.withUnsafeBytes {
        tex.replace(region: MTLRegionMake2D(0, 0, tex.width, tex.height),
                    mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: tex.width * 4)
    }
}
func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

print("Metal fragment-pass benchmark on \(device.name); not a phone thermal measurement")
for (width, height) in [(256, 128), (1024, 512)] {
    let backdrop = texture(width, height)
    let geometry = texture(width, height)
    let outputs = [texture(width, height, target: true), texture(width, height, target: true)]
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    var normals = pixels
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            let value: UInt8 = ((x / 9 + y / 7) % 2 == 0) ? 20 : 235
            pixels[i] = y % 2 == 0 ? value : 165
            pixels[i + 1] = y % 2 == 0 ? 255 - value : 115
            pixels[i + 2] = y % 2 == 0 ? UInt8(x % 256) : 140
            let px = Double(x) + 0.5 - Double(width) / 2
            let py = Double(y) + 0.5 - Double(height) / 2
            let cx = max(abs(px) - Double(width - height) / 2, 0) * (px < 0 ? -1 : 1)
            let r = max(sqrt(cx * cx + py * py), 0.001)
            let edge = Double(height) / 2 - r
            let slope = max(0, min(1, 1 - edge / 32))
            normals[i] = UInt8((255 * (0.5 + 0.5 * slope * cx / r)).rounded())
            normals[i + 1] = UInt8((255 * (0.5 + 0.5 * slope * py / r)).rounded())
            normals[i + 2] = UInt8((255 * sqrt(1 - slope * slope)).rounded())
            normals[i + 3] = UInt8((255 * max(0, min(1, edge))).rounded())
        }
    }
    upload(pixels, backdrop)
    upload(normals, geometry)
    for dark in [false, true] {
        let uniforms: [[Float]] = [
            [Float(width), Float(height)], [0, 0], [Float(width), Float(height)],
            [0.97, 0.97, 0.97, dark ? 0.12 : 0.53], [1.24, 0, 32, 1],
            [0, 0, dark ? 1.4 : 2.1], [0, dark ? -1 : 1], [0], [1], [0],
            [0, 0, 0, 0], [0, 0], [0, 0, 1, 0.035], [0], [0], [0, 0], [0],
            [dark ? 0.45 : 1, 1, dark ? 0 : 0.32, 0], [1],
            [dark ? 0.85 : 0.73, dark ? -0.45 : 0.4, 1.8, dark ? 2.5 : 0.8],
        ]
        let batch = 16
        func measure(_ index: Int) -> Double {
            let command = queue.makeCommandBuffer()!
            for _ in 0..<batch {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = outputs[index]
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
                encoder.setRenderPipelineState(pipelines[index])
                var size = SIMD2<Float>(Float(width), Float(height))
                encoder.setVertexBytes(&size, length: MemoryLayout.size(ofValue: size), index: 0)
                for (slot, values) in uniforms.enumerated() {
                    let padded = values + Array(repeating: Float(0), count: max(0, 4 - values.count))
                    padded.withUnsafeBytes {
                        encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: slot)
                    }
                }
                encoder.setFragmentTexture(backdrop, index: 0)
                encoder.setFragmentTexture(geometry, index: 1)
                encoder.setFragmentSamplerState(nearestSampler, index: 0)
                encoder.setFragmentSamplerState(linearSampler, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
            command.commit()
            command.waitUntilCompleted()
            precondition(command.status == .completed, "\(String(describing: command.error))")
            return (command.gpuEndTime - command.gpuStartTime) * 1000 / Double(batch)
        }
        for _ in 0..<4 { _ = measure(0); _ = measure(1) }
        var times = [[Double](), [Double]()]
        for round in 0..<20 {
            for index in (round % 2 == 0 ? [0, 1] : [1, 0]) {
                times[index].append(measure(index))
            }
        }
        var before = pixels
        var after = pixels
        outputs[0].getBytes(&before, bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        outputs[1].getBytes(&after, bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let maxDelta = zip(before, after).map { abs(Int($0) - Int($1)) }.max()!
        precondition(maxDelta <= 1, "Metal pixel mismatch: \(maxDelta)/255")
        let old = median(times[0]), new = median(times[1])
        print(String(format: "%dx%d %@: reference %.4f ms, current %.4f ms, %.1f%% reduction; max pixel delta %d/255",
            width, height, dark ? "dark" : "light", old, new, (1 - new / old) * 100, maxDelta))
    }
}
