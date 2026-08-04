// The matrix multiply behind tok2vec, the tagger softmax and the NER parser.
//
// Two implementations of one operation:
//
//   * `accelerateGemmT` — Accelerate's `cblas_sgemm`. Roughly 4.7x faster at
//     the shapes this model actually uses (7.5x in the encoder blocks, 20x on
//     large batches), which is 2.5x on the whole NLP stage for paragraph-length
//     documents and less on short ones, because embedding lookups and the
//     transition system do not speed up. Compiled in when the
//     `PresidioAccelerate` trait is enabled *and* Accelerate exists — the
//     trait is on by default, so on Apple platforms this is what runs.
//
//   * `portableGemmT` — hand-written SIMD, no dependencies. What runs on Linux,
//     Android and Windows, where `canImport(Accelerate)` is false and the trait
//     being enabled changes nothing.
//
// Note which of those two is load-bearing for portability. A default trait is
// enabled on *every* platform, so `canImport(Accelerate)` is the whole reason
// the non-Apple build still works, and `portableGemmT` must never end up inside
// a `#if` -- Tools/check_portability.sh enforces exactly that, and the Linux CI
// job asserts the fallback actually happens rather than trusting the guard.
//
// The trait exists so this can be turned off (`traits: []`, or
// `--disable-default-traits`). Not for correctness: measured over the full
// parity corpora the *outcomes* are identical -- 5,513/5,513 tags, 5,513/5,513
// lemmas, 2,588/2,592 entities either way, and not one argmax flips -- but ~93%
// of individual float values differ in their last bits (max delta 3.6e-05). If
// you need macOS and Linux to agree bit for bit rather than answer for answer,
// that is the switch. CI runs both against the same gold corpora.

#if PresidioAccelerate && canImport(Accelerate)
import Accelerate
#endif

/// Which kernel this build was compiled with.
///
/// Public because it is the honest answer to "which one am I actually running?"
/// -- a guard that silently fell through would look exactly like one that
/// worked. CI greps for it three times: to prove the Apple default is
/// Accelerate, that Linux falls back, and that both parity columns really did
/// compile different kernels.
public enum MatrixKernel {

    /// True when the `PresidioAccelerate` trait is on and Accelerate was found.
    public static let usesAccelerate: Bool = {
        #if PresidioAccelerate && canImport(Accelerate)
        return true
        #else
        return false
        #endif
    }()

    public static var name: String {
        usesAccelerate ? "Accelerate (cblas_sgemm)" : "portable SIMD"
    }
}

// C[T,N] += A[T,K] * W[N,K]^T   (W row-major N x K)
@inline(__always)
func gemmT(_ A: UnsafePointer<Float>, _ W: UnsafePointer<Float>, _ C: UnsafeMutablePointer<Float>,
           _ T: Int, _ K: Int, _ N: Int) {
    #if PresidioAccelerate && canImport(Accelerate)
    accelerateGemmT(A, W, C, T, K, N)
    #else
    portableGemmT(A, W, C, T, K, N)
    #endif
}

#if PresidioAccelerate && canImport(Accelerate)
/// `beta = 1`, not 0: every caller pre-fills `C` with the layer's bias and
/// expects the product to accumulate onto it. Passing 0 here silently drops
/// every bias in the network.
@inline(__always)
func accelerateGemmT(_ A: UnsafePointer<Float>, _ W: UnsafePointer<Float>,
                     _ C: UnsafeMutablePointer<Float>,
                     _ T: Int, _ K: Int, _ N: Int) {
    cblas_sgemm(
        CblasRowMajor, CblasNoTrans, CblasTrans,
        Int32(T), Int32(N), Int32(K),
        1, A, Int32(K), W, Int32(K),
        1, C, Int32(N)
    )
}
#endif

/// 2x2 register-blocked, eight lanes at a time.
///
/// Always compiled, never conditional. It is the kernel every non-Apple
/// platform runs, *and* the reference the Accelerate path is checked against —
/// so even a build that never calls it still has both available to compare.
func portableGemmT(_ A: UnsafePointer<Float>, _ W: UnsafePointer<Float>, _ C: UnsafeMutablePointer<Float>,
                   _ T: Int, _ K: Int, _ N: Int) {
    let K8 = K & ~7
    var t = 0
    while t + 2 <= T {
        let a0p = A + t*K, a1p = A + (t+1)*K
        let c0 = C + t*N, c1 = C + (t+1)*N
        var n = 0
        while n + 2 <= N {
            let w0 = W + n*K, w1 = W + (n+1)*K
            var r00 = SIMD8<Float>(), r01 = SIMD8<Float>(), r10 = SIMD8<Float>(), r11 = SIMD8<Float>()
            var k = 0
            while k < K8 {
                let av0 = SIMD8<Float>(a0p[k],a0p[k+1],a0p[k+2],a0p[k+3],a0p[k+4],a0p[k+5],a0p[k+6],a0p[k+7])
                let av1 = SIMD8<Float>(a1p[k],a1p[k+1],a1p[k+2],a1p[k+3],a1p[k+4],a1p[k+5],a1p[k+6],a1p[k+7])
                let wv0 = SIMD8<Float>(w0[k],w0[k+1],w0[k+2],w0[k+3],w0[k+4],w0[k+5],w0[k+6],w0[k+7])
                let wv1 = SIMD8<Float>(w1[k],w1[k+1],w1[k+2],w1[k+3],w1[k+4],w1[k+5],w1[k+6],w1[k+7])
                r00.addProduct(av0, wv0); r01.addProduct(av0, wv1)
                r10.addProduct(av1, wv0); r11.addProduct(av1, wv1)
                k += 8
            }
            var s00 = r00.sum(), s01 = r01.sum(), s10 = r10.sum(), s11 = r11.sum()
            while k < K { s00 += a0p[k]*w0[k]; s01 += a0p[k]*w1[k]; s10 += a1p[k]*w0[k]; s11 += a1p[k]*w1[k]; k += 1 }
            c0[n] += s00; c0[n+1] += s01; c1[n] += s10; c1[n+1] += s11
            n += 2
        }
        while n < N {
            let w = W + n*K
            var s0: Float = 0, s1: Float = 0
            for k in 0..<K { s0 += a0p[k]*w[k]; s1 += a1p[k]*w[k] }
            c0[n] += s0; c1[n] += s1; n += 1
        }
        t += 2
    }
    while t < T {
        let a = A + t*K, c = C + t*N
        for n in 0..<N {
            let w = W + n*K
            var acc = SIMD8<Float>(); var k = 0
            while k < K8 {
                acc.addProduct(SIMD8<Float>(a[k],a[k+1],a[k+2],a[k+3],a[k+4],a[k+5],a[k+6],a[k+7]),
                               SIMD8<Float>(w[k],w[k+1],w[k+2],w[k+3],w[k+4],w[k+5],w[k+6],w[k+7]))
                k += 8
            }
            var s = acc.sum(); while k < K { s += a[k]*w[k]; k += 1 }
            c[n] += s
        }
        t += 1
    }
}
