#include <metal_stdlib>
using namespace metal;

// Keeps medium/high confidence samples for the GPU pre-filter path. The CPU
// reference fusion remains active as a portable, auditable fallback.
kernel void depthforgeConfidenceMask(const device uchar *confidence [[buffer(0)]],
                                     device uchar *mask [[buffer(1)]],
                                     uint id [[thread_position_in_grid]]) {
    mask[id] = confidence[id] >= 1 ? 1 : 0;
}
