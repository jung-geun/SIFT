// Copyright © 2026 Apple Inc.
// SIFT modification: validate floating-point support without an unused binding.

import Foundation

extension MLXArray {
    /// Scalar masked-score fill (`-finfo(dtype).max`) constructed directly in
    /// `dtype`, so masked positions vanish under softmax — no `asType` to forget.
    public static func maskFill(for dtype: DType) -> MLXArray {
        guard dtype.finfo != nil else {
            fatalError("maskFill requires a floating-point dtype, got \(dtype)")
        }
        return -dtype.greatestFiniteMagnitudeArray
    }
}
