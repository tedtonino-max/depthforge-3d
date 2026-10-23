import Foundation
#if canImport(Metal)
import Metal

/// Metal availability is probed at runtime. CPU fusion remains the deterministic
/// fallback, while this compute kernel provides the first GPU reduction stage
/// for devices that can execute it.
final class MetalFusionAccelerator {
    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLComputePipelineState?
    init() {
        let selectedDevice = MTLCreateSystemDefaultDevice()
        device = selectedDevice
        queue = selectedDevice?.makeCommandQueue()
        if let selectedDevice,
           let function = selectedDevice.makeDefaultLibrary()?.makeFunction(name: "depthforgeConfidenceMask") {
            pipeline = try? selectedDevice.makeComputePipelineState(function: function)
        } else {
            pipeline = nil
        }
    }
    var isAvailable: Bool { device != nil && queue != nil && pipeline != nil }
}
#else
final class MetalFusionAccelerator { var isAvailable: Bool { false } }
#endif
