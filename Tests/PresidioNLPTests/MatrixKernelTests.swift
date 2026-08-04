import Testing
import Foundation
@testable import PresidioNLP

/// The matrix multiply, checked directly rather than only through its effect on
/// entity spans.
///
/// There are two kernels — the portable SIMD one and, behind the
/// `PresidioAccelerate` trait, Accelerate's `cblas_sgemm` — and the whole
/// argument for offering the second is that it does not change any outcome. That
/// claim is worth checking at the level where a discrepancy is a number rather
/// than a missing PERSON three layers up.
///
/// Runs without a model: these are the shapes the model uses, on synthetic
/// weights, so the suite is not gated on `SPACY_MODEL_DIR`.
@Suite("matrix kernel")
struct MatrixKernelTests {

    /// The shapes `runNER` and the tagger actually call `gemmT` with, plus one
    /// large batch. Named, because a bug that only shows up in the encoder
    /// blocks should say "encoder" when it fails.
    static let shapes: [(name: String, T: Int, K: Int, N: Int)] = [
        ("embed maxout", 14, 576, 288),
        ("encoder block", 22, 288, 288),
        ("parser linear", 14, 96, 64),
        ("odd tail", 7, 100, 37),      // T, K and N all indivisible by the blocking
        ("single token", 1, 288, 288), // exercises the T-odd path on its own
        // A long text, kept to 64 tokens rather than a realistic 256: the
        // double-precision reference is O(T*K*N) in an unoptimised build, and a
        // reference that makes the default `swift test` noticeably slower is a
        // reference people start skipping.
        ("long text", 64, 576, 288),
    ]

    /// Deterministic, so a failure reproduces. Values in [-1, 1) like trained
    /// weights, rather than [0, 1) — sign cancellation is where accumulation
    /// order shows up, and an all-positive corpus would hide it.
    static func noise(_ count: Int, seed: UInt64) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(bitPattern: UInt32(truncatingIfNeeded: state >> 33))) / Float(Int32.max)
        }
    }

    /// The definition of the operation, written the obvious way.
    static func reference(
        _ a: [Float], _ w: [Float], _ c: [Float], _ T: Int, _ K: Int, _ N: Int
    ) -> [Double] {
        var out = [Double](repeating: 0, count: T * N)
        for t in 0..<T {
            for n in 0..<N {
                var sum = Double(c[t * N + n])
                for k in 0..<K { sum += Double(a[t * K + k]) * Double(w[n * K + k]) }
                out[t * N + n] = sum
            }
        }
        return out
    }

    static func run(
        _ kernel: (UnsafePointer<Float>, UnsafePointer<Float>, UnsafeMutablePointer<Float>,
                   Int, Int, Int) -> Void,
        _ a: [Float], _ w: [Float], _ bias: [Float], _ T: Int, _ K: Int, _ N: Int
    ) -> [Float] {
        var c = bias
        a.withUnsafeBufferPointer { ap in
            w.withUnsafeBufferPointer { wp in
                c.withUnsafeMutableBufferPointer { cp in
                    kernel(ap.baseAddress!, wp.baseAddress!, cp.baseAddress!, T, K, N)
                }
            }
        }
        return c
    }

    /// Prints which kernel this build compiled. CI greps for this line in both
    /// jobs: a trait that silently did nothing would otherwise be indistinguishable
    /// from a trait that worked, and the fast job would be testing the slow path.
    @Test("reports which kernel is compiled in")
    func reportsKernel() {
        print("matrix kernel: \(MatrixKernel.name)")
        #expect(!MatrixKernel.name.isEmpty)
    }

    /// `gemmT` accumulates onto `C` rather than overwriting it, because every
    /// caller pre-fills it with the layer's bias. An implementation that used
    /// `beta = 0` would pass a shape test and drop every bias in the network,
    /// so it is asserted separately from the arithmetic.
    @Test("the product accumulates onto C instead of replacing it")
    func accumulatesOntoBias() {
        // T=1, K=4, N=2: one token, two output rows of four weights each.
        let a: [Float] = [1, 1, 1, 1]
        let w: [Float] = [1, 1, 1, 1, 1, 1, 1, 1]
        let bias: [Float] = [100, 200]
        for (label, kernel) in Self.kernels {
            #expect(Self.run(kernel, a, w, bias, 1, 4, 2) == [104, 204], "\(label)")
        }
    }

    @Test("each kernel matches a double-precision reference", arguments: shapes)
    func matchesReference(shape: (name: String, T: Int, K: Int, N: Int)) {
        let (_, T, K, N) = shape
        let a = Self.noise(T * K, seed: 1)
        let w = Self.noise(N * K, seed: 2)
        let bias = Self.noise(T * N, seed: 3)
        let want = Self.reference(a, w, bias, T, K, N)

        for (label, kernel) in Self.kernels {
            let got = Self.run(kernel, a, w, bias, T, K, N)
            var worst = 0.0
            for i in 0..<(T * N) { worst = max(worst, abs(Double(got[i]) - want[i])) }
            // Float32 over a K-long dot product: ~1e-4 is the honest bound at
            // K=576, and both kernels sit well inside it.
            #expect(worst < 1e-3, "\(label) on \(shape.name): max delta \(worst)")
        }
    }

    /// The claim the trait rests on: same answers, different last bits.
    ///
    /// Skipped in a default build, where there is only one kernel to compare.
    @Test(
        "Accelerate and the portable kernel agree",
        .enabled(if: MatrixKernel.usesAccelerate),
        arguments: shapes
    )
    func kernelsAgree(shape: (name: String, T: Int, K: Int, N: Int)) {
        let (_, T, K, N) = shape
        let a = Self.noise(T * K, seed: 11)
        let w = Self.noise(N * K, seed: 12)
        let bias = Self.noise(T * N, seed: 13)

        let fast = Self.run(gemmT, a, w, bias, T, K, N)
        let portable = Self.run(portableGemmT, a, w, bias, T, K, N)

        var worst: Float = 0
        for i in 0..<(T * N) { worst = max(worst, abs(fast[i] - portable[i])) }
        #expect(worst < 1e-3, "\(shape.name): max delta \(worst)")
    }

    static var kernels: [(String, (UnsafePointer<Float>, UnsafePointer<Float>,
                                   UnsafeMutablePointer<Float>, Int, Int, Int) -> Void)] {
        var out: [(String, (UnsafePointer<Float>, UnsafePointer<Float>,
                            UnsafeMutablePointer<Float>, Int, Int, Int) -> Void)] = [
            ("portable", portableGemmT)
        ]
        if MatrixKernel.usesAccelerate { out.append(("accelerate", gemmT)) }
        return out
    }
}
