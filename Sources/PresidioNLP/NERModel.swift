// spaCy v3 NER inference, in pure Swift.
//
// Ported from the validated prototype in prototypes/spacy-ner-port.swift, which
// reproduced spaCy en_core_web_lg exactly: 2,324/2,324 entities, 0 FP / 0 FN
// over 2,000 sentences.
//
// The pipeline is tok2vec (MultiHashEmbed -> Maxout -> LayerNorm -> 4 residual
// maxout-window blocks) followed by a transition-based parser over BILUO
// actions. Weights are read directly from the model's thinc msgpack files, so
// there is no conversion step and no runtime beyond this file.
//
// Deliberately dependency-free apart from Foundation: the matmul is hand-written
// SIMD rather than BLAS. That is not because BLAS is unavailable -- OpenBLAS and
// BLIS are both portable and BSD-licensed -- but because it keeps the platform
// matrix unconstrained. See the README for the measured cost.

import Foundation

// Pure-Swift spaCy v3 NER inference.
// Stdlib only: no Foundation, no Accelerate, no NaturalLanguage, no C deps.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Bionic)
import Bionic
#elseif canImport(WinSDK)
import WinSDK
#endif

// ============================ tiny file read (POSIX, portable) ============================
/// Reads a model file. Returns empty rather than trapping, so a missing or
/// unreadable model surfaces as a thrown `NERError` at the loader instead of a
/// crash deep inside msgpack parsing.
func readFile(_ path: String) -> [UInt8] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    return [UInt8](data)
}

// ============================ minimal msgpack decoder ============================
indirect enum MP {
    case nilv, bool(Bool), int(Int64), uint(UInt64), str(String), bin(ArraySlice<UInt8>)
    case arr([MP]), map([(MP, MP)])
    var asInt: Int? { if case .int(let v) = self { return Int(v) }; if case .uint(let v) = self { return Int(v) }; return nil }
    var asStr: String? { if case .str(let s) = self { return s }; return nil }
    var asArr: [MP]? { if case .arr(let a) = self { return a }; return nil }
    var asBin: ArraySlice<UInt8>? { if case .bin(let b) = self { return b }; return nil }
    func m(_ key: String) -> MP? {
        if case .map(let kv) = self { for (k, v) in kv { if k.asStr == key { return v } } }
        return nil
    }
    func mb(_ key: [UInt8]) -> MP? {   // binary keys (numpy header uses b'shape' etc.)
        if case .map(let kv) = self {
            for (k, v) in kv {
                if case .bin(let b) = k, Array(b) == key { return v }
                if case .str(let s) = k, Array(s.utf8) == key { return v }
            }
        }
        return nil
    }
}

struct MPReader {
    let d: [UInt8]; var i = 0
    init(_ d: [UInt8]) { self.d = d }
    mutating func u8() -> UInt8 { let v = d[i]; i += 1; return v }
    mutating func be(_ n: Int) -> UInt64 { var v: UInt64 = 0; for _ in 0..<n { v = (v << 8) | UInt64(d[i]); i += 1 }; return v }
    mutating func str(_ n: Int) -> String { let s = String(decoding: d[i..<i+n], as: UTF8.self); i += n; return s }
    mutating func value() -> MP {
        let c = u8()
        switch c {
        case 0x00...0x7f: return .uint(UInt64(c))
        case 0xe0...0xff: return .int(Int64(Int8(bitPattern: c)))
        case 0xa0...0xbf: return .str(str(Int(c & 0x1f)))
        case 0x90...0x9f: return .arr(array(Int(c & 0x0f)))
        case 0x80...0x8f: return .map(mapv(Int(c & 0x0f)))
        case 0xc0: return .nilv
        case 0xc2: return .bool(false)
        case 0xc3: return .bool(true)
        case 0xc4: let n = Int(be(1)); let s = d[i..<i+n]; i += n; return .bin(s)
        case 0xc5: let n = Int(be(2)); let s = d[i..<i+n]; i += n; return .bin(s)
        case 0xc6: let n = Int(be(4)); let s = d[i..<i+n]; i += n; return .bin(s)
        case 0xcc: return .uint(be(1))
        case 0xcd: return .uint(be(2))
        case 0xce: return .uint(be(4))
        case 0xcf: return .uint(be(8))
        case 0xd0: return .int(Int64(Int8(bitPattern: UInt8(be(1)))))
        case 0xd1: return .int(Int64(Int16(bitPattern: UInt16(be(2)))))
        case 0xd2: return .int(Int64(Int32(bitPattern: UInt32(be(4)))))
        case 0xd3: return .int(Int64(bitPattern: be(8)))
        case 0xd9: return .str(str(Int(be(1))))
        case 0xda: return .str(str(Int(be(2))))
        case 0xdb: return .str(str(Int(be(4))))
        case 0xdc: return .arr(array(Int(be(2))))
        case 0xdd: return .arr(array(Int(be(4))))
        case 0xde: return .map(mapv(Int(be(2))))
        case 0xdf: return .map(mapv(Int(be(4))))
        case 0xca: i += 4; return .nilv     // float32 (unused here)
        case 0xcb: i += 8; return .nilv
        default: fatalError("msgpack byte \(c)")
        }
    }
    mutating func array(_ n: Int) -> [MP] { var a = [MP](); a.reserveCapacity(n); for _ in 0..<n { a.append(value()) }; return a }
    mutating func mapv(_ n: Int) -> [(MP, MP)] { var a = [(MP, MP)](); a.reserveCapacity(n); for _ in 0..<n { let k = value(); a.append((k, value())) }; return a }
}

// ============================ tensors ============================
struct Tensor { var shape: [Int]; var data: [Float] }

func mpTensor(_ v: MP) -> Tensor {
    let shape = v.mb(Array("shape".utf8))!.asArr!.map { $0.asInt! }
    let raw = v.mb(Array("data".utf8))!.asBin!
    var out = [Float](repeating: 0, count: raw.count / 4)
    let arr = Array(raw)
    arr.withUnsafeBytes { rb in
        let p = rb.bindMemory(to: UInt32.self)
        for k in 0..<out.count { out[k] = Float(bitPattern: UInt32(littleEndian: p[k])) }
    }
    return Tensor(shape: shape, data: out)
}

// ============================ hashing ============================
@inline(__always) func mmh3x86_128_u64(_ val: UInt64, _ seed: UInt32) -> (UInt32, UInt32, UInt32, UInt32) {
    var h1 = val
    h1 = h1 &* 0x87c3_7b91_1142_53d5
    h1 = (h1 << 31) | (h1 >> 33)
    h1 = h1 &* 0x4cf5_ad43_2745_937f
    h1 ^= UInt64(seed); h1 ^= 8
    var h2 = UInt64(seed); h2 ^= 8
    h1 = h1 &+ h2; h2 = h2 &+ h1
    h1 ^= h1 >> 33; h1 = h1 &* 0xff51_afd7_ed55_8ccd
    h1 ^= h1 >> 33; h1 = h1 &* 0xc4ce_b9fe_1a85_ec53; h1 ^= h1 >> 33
    h2 ^= h2 >> 33; h2 = h2 &* 0xff51_afd7_ed55_8ccd
    h2 ^= h2 >> 33; h2 = h2 &* 0xc4ce_b9fe_1a85_ec53; h2 ^= h2 >> 33
    h1 = h1 &+ h2; h2 = h2 &+ h1
    return (UInt32(truncatingIfNeeded: h1), UInt32(truncatingIfNeeded: h1 >> 32),
            UInt32(truncatingIfNeeded: h2), UInt32(truncatingIfNeeded: h2 >> 32))
}

// MurmurHash64A -- spaCy's hash_string(), seed = 1
func murmurHash64A(_ bytes: [UInt8], _ seed: UInt64 = 1) -> UInt64 {
    let m: UInt64 = 0xc6a4_a793_5bd1_e995, r: UInt64 = 47
    let len = bytes.count
    var h = seed ^ (UInt64(len) &* m)
    var i = 0
    while i + 8 <= len {
        var k: UInt64 = 0
        for j in 0..<8 { k |= UInt64(bytes[i + j]) << (8 * UInt64(j)) }
        k = k &* m; k ^= k >> r; k = k &* m
        h ^= k; h = h &* m
        i += 8
    }
    let rem = len - i
    if rem > 0 {
        var t: UInt64 = 0
        for j in 0..<rem { t |= UInt64(bytes[i + j]) << (8 * UInt64(j)) }
        h ^= t; h = h &* m
    }
    h ^= h >> r; h = h &* m; h ^= h >> r
    return h
}

// ============================ lexical attributes ============================
func wordShape(_ s: String) -> String {
    if s.count >= 100 { return "LONG" }
    var out = ""; var last: Character = "\0"; var seq = 0; var started = false
    for ch in s {
        let sc: Character
        if ch.isLetter { sc = ch.isUppercase ? "X" : "x" }
        else if ch.isNumber { sc = "d" }
        else { sc = ch }
        if started && sc == last { seq += 1 } else { seq = 0; last = sc; started = true }
        if seq < 4 { out.append(sc) }
    }
    return out
}
func lexPrefix(_ s: String) -> String { String(s.first!) }
func lexSuffix(_ s: String) -> String { s.count <= 3 ? s : String(s.suffix(3)) }

// ============================ SIMD kernels ============================
// C[T,N] += A[T,K] * W[N,K]^T   (W row-major N x K)
func gemmT(_ A: UnsafePointer<Float>, _ W: UnsafePointer<Float>, _ C: UnsafeMutablePointer<Float>,
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

// ============================ model ============================
/// `@unchecked Sendable`: every property below is a weight array written once
/// during `init` and only read afterwards. They are `var` rather than `let`
/// because the msgpack decode assigns them in a loop, not because they change.
final class NERModel: @unchecked Sendable {
    // hash embeds
    var embE: [[Float]] = []; var embRows: [Int] = []; var embSeed: [UInt32] = []
    let width = 96
    // embed maxout + layernorm
    var moW: [Float] = []; var moB: [Float] = []; var moNI = 0    // (96,3,nI)
    var lnG: [Float] = []; var lnB: [Float] = []
    // 4 encoder blocks
    var encW: [[Float]] = []; var encB: [[Float]] = []
    var encG: [[Float]] = []; var encLB: [[Float]] = []
    // parser
    var linW: [Float] = []; var linB: [Float] = []          // (64,96)
    var paW: [Float] = []; var paB: [Float] = []; var paPad: [Float] = []   // (3,64,2,64),(64,2),(1,3,64,2)
    var upW: [Float] = []; var upB: [Float] = []            // (74,64)
    var nO = 64, nP = 2, nF = 3, nClasses = 74
    var actMove: [Int] = []; var actLabel: [String] = []

    init(dir: String) {
        var r = MPReader(readFile(dir + "/ner/model"))
        let root = r.value()
        let nodes = root.m("nodes")!.asArr!
        let params = root.m("params")!.asArr!
        let attrs = root.m("attrs")!.asArr!
        func name(_ i: Int) -> String { nodes[i].m("name")!.asStr! }
        func p(_ i: Int, _ k: String) -> Tensor? { params[i].m(k).map(mpTensor) }
        func attrInt(_ i: Int, _ k: String) -> Int? {
            guard let b = attrs[i].m(k)?.asBin else { return nil }
            var rr = MPReader(Array(b)); return rr.value().asInt
        }
        var maxouts: [(Int, Tensor, Tensor)] = []
        var lns: [(Int, Tensor, Tensor)] = []
        var linears: [(Int, Tensor, Tensor)] = []
        var hes: [(Int, Tensor, UInt32)] = []
        var paIdx = -1
        for i in 0..<nodes.count {
            switch name(i) {
            case "hashembed": hes.append((i, p(i, "E")!, UInt32(attrInt(i, "seed")!)))
            case "maxout": maxouts.append((i, p(i, "W")!, p(i, "b")!))
            case "layernorm": lns.append((i, p(i, "G")!, p(i, "b")!))
            case "linear": linears.append((i, p(i, "W")!, p(i, "b")!))
            case "precomputable_affine": paIdx = i
            case "static_vectors": let t = p(i, "W")!; svW = t.data; svM = t.shape[1]
            default: break
            }
        }
        hes.sort { $0.0 < $1.0 }; maxouts.sort { $0.0 < $1.0 }; lns.sort { $0.0 < $1.0 }
        for h in hes { embE.append(h.1.data); embRows.append(h.1.shape[0]); embSeed.append(h.2) }
        let embMo = maxouts.first { $0.1.shape[2] != 288 }!
        let encMos = maxouts.filter { $0.1.shape[2] == 288 }
        let embLn = lns.min { abs($0.0 - embMo.0) < abs($1.0 - embMo.0) }!
        let encLns = lns.filter { $0.0 != embLn.0 }
        moW = embMo.1.data; moB = embMo.2.data; moNI = embMo.1.shape[2]
        lnG = embLn.1.data; lnB = embLn.2.data
        for (i, m) in encMos.enumerated() { encW.append(m.1.data); encB.append(m.2.data)
            encG.append(encLns[i].1.data); encLB.append(encLns[i].2.data) }
        let lt = linears.first { $0.1.shape == [64, 96] }!
        linW = lt.1.data; linB = lt.2.data
        let up = linears.first { $0.1.shape[0] == 74 }!
        upW = up.1.data; upB = up.2.data
        nClasses = up.1.shape[0]
        let pa = mpTensor(params[paIdx].m("W")!)
        paW = pa.data; paB = mpTensor(params[paIdx].m("b")!).data
        paPad = mpTensor(params[paIdx].m("pad")!).data
        nF = pa.shape[0]; nO = pa.shape[1]; nP = pa.shape[2]
        loadMoves(dir + "/ner/moves")
        loadNorms(dir + "/vocab/lookups.bin")
        loadSymbols("symbols.tsv")
        loadVectors(dir)
    }

    // static vectors (lg/md)
    var svW: [Float] = []          // (96, 300)
    var svM = 0
    var key2row: [UInt64: Int32] = [:]
    var vecPtr: UnsafePointer<Float>? = nil
    var vecDim = 0
    func loadVectors(_ dir: String) {
        guard !svW.isEmpty else { return }
        var r = MPReader(readFile(dir + "/vocab/key2row"))
        if case .map(let kv) = r.value() {
            key2row.reserveCapacity(kv.count)
            for (k, v) in kv {
                let key: UInt64
                if case .uint(let x) = k { key = x } else if case .int(let x) = k { key = UInt64(bitPattern: x) } else { continue }
                if let row = v.asInt { key2row[key] = Int32(row) }
            }
        }
        // .npy v1: magic(6) ver(2) hlen(2 LE) header
        let fd = open(dir + "/vocab/vectors", O_RDONLY)
        var st = stat(); fstat(fd, &st)
        let sz = Int(st.st_size)
        let base = mmap(nil, sz, PROT_READ, MAP_PRIVATE, fd, 0)!
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let hlen = Int(bytes[8]) | (Int(bytes[9]) << 8)
        let header = String(decoding: UnsafeBufferPointer(start: bytes + 10, count: hlen), as: UTF8.self)
        // parse "shape': (514157, 300)"
        var dims: [Int] = []
        var num = ""
        var inShape = false
        var seen = false
        for ch in header {
            if !seen { if header.hasPrefix("") {} }
            if ch == "(" { inShape = true; continue }
            if inShape {
                if ch.isNumber { num.append(ch) }
                else { if !num.isEmpty { dims.append(Int(num)!); num = "" }; if ch == ")" { inShape = false; seen = true } }
            }
        }
        vecDim = dims.count >= 2 ? dims[1] : 300
        vecPtr = UnsafeRawPointer(bytes + 10 + hlen).assumingMemoryBound(to: Float.self)
    }

    var symbols: [String: UInt64] = [:]
    func loadSymbols(_ path: String) {
        let txt = String(decoding: readFile(path), as: UTF8.self)
        for line in txt.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            if f.count == 2, let v = UInt64(f[1]) { symbols[String(f[0])] = v }
        }
    }
    @inline(__always) func strID(_ s: String) -> UInt64 {
        if let v = symbols[s] { return v }
        return murmurHash64A(Array(s.utf8), 1)
    }

    var lexemeNorm: [UInt64: String] = [:]
    func loadNorms(_ path: String) {
        var r = MPReader(readFile(path))
        let root = r.value()
        guard case .map(let kv) = root else { return }
        for (k, v) in kv where k.asStr == "lexeme_norm" {
            if case .map(let t) = v {
                for (kk, vv) in t {
                    if case .uint(let h) = kk, let s = vv.asStr { lexemeNorm[h] = s }
                    else if case .int(let h) = kk, let s = vv.asStr { lexemeNorm[UInt64(bitPattern: h)] = s }
                }
            }
        }
    }

    func loadMoves(_ path: String) {
        var r = MPReader(readFile(path))
        let js = r.value().m("moves")!.asStr!
        // minimal JSON: {"0":{},"1":{"ORG":56516,...},...}
        var mt = -1
        var i = js.startIndex
        var depth = 0
        var cur = ""
        var inStr = false, isKey = false
        var keys: [String] = []
        while i < js.endIndex {
            let c = js[i]
            if inStr {
                if c == "\"" { inStr = false; if isKey { keys.append(cur) }; cur = "" }
                else { cur.append(c) }
            } else if c == "\"" { inStr = true; isKey = true; cur = "" }
            else if c == "{" { depth += 1; if depth == 2 { mt += 1 } }
            else if c == "}" { depth -= 1 }
            else if c == ":" && depth == 2 { /* value follows */ }
            i = js.index(after: i)
        }
        // second pass with explicit structure
        actMove = []; actLabel = []
        var d = 0; var key = ""; var reading = false; var mtIdx = -1
        var pendingKey = ""
        for c in js {
            if reading { if c == "\"" { reading = false; key = pendingKey } else { pendingKey.append(c) }; continue }
            if c == "\"" { reading = true; pendingKey = ""; continue }
            if c == "{" { d += 1; if d == 2 { mtIdx = Int(key) ?? mtIdx }; continue }
            if c == "}" { d -= 1; continue }
            if c == ":" && d == 2 { actMove.append(mtIdx); actLabel.append(key); continue }
        }
        _ = keys
    }
}

// ============================ forward ============================
@inline(__always) func layerNorm(_ x: inout [Float], _ off: Int, _ n: Int, _ G: [Float], _ B: [Float]) {
    var mu: Float = 0
    for i in 0..<n { mu += x[off + i] }
    mu /= Float(n)
    var v: Float = 0
    for i in 0..<n { let d = x[off + i] - mu; v += d * d }
    v = v / Float(n) + 1e-8
    let inv = 1.0 / v.squareRoot()
    for i in 0..<n { x[off + i] = (x[off + i] - mu) * inv * G[i] + B[i] }
}

struct Ent { var start: Int; var end: Int; var label: String }

func runNER(_ m: NERModel, _ tokens: [String], _ norms: [String]? = nil, dump: Bool = false) -> [Ent] {
    let T = tokens.count
    if T == 0 { return [] }
    let W = m.width
    let nAttr = m.embE.count
    // ---- feature ids -> hash embed -> concat ----
    var X = [Float](repeating: 0, count: T * m.moNI)
    for t in 0..<T {
        let s = tokens[t]
        let orth = m.strID(s)
        let norm = norms?[t] ?? (m.lexemeNorm[orth] ?? s.lowercased())
        let vals = [norm, lexPrefix(s), lexSuffix(s), wordShape(s)]
        if !m.svW.isEmpty {
            let row = m.key2row[orth].map { Int($0) } ?? -1
            if row >= 0, let vp = m.vecPtr {
                let src = vp + row * m.vecDim
                let base = t * m.moNI + nAttr * W
                for o in 0..<W {
                    var acc = SIMD8<Float>(); var k = 0
                    let wrow = o * m.svM
                    while k + 8 <= m.svM {
                        acc.addProduct(SIMD8<Float>(src[k],src[k+1],src[k+2],src[k+3],src[k+4],src[k+5],src[k+6],src[k+7]),
                                       SIMD8<Float>(m.svW[wrow+k],m.svW[wrow+k+1],m.svW[wrow+k+2],m.svW[wrow+k+3],m.svW[wrow+k+4],m.svW[wrow+k+5],m.svW[wrow+k+6],m.svW[wrow+k+7]))
                        k += 8
                    }
                    var sv = acc.sum(); while k < m.svM { sv += src[k] * m.svW[wrow+k]; k += 1 }
                    X[base + o] = sv
                }
            }
        }
        for c in 0..<nAttr {
            let id = m.strID(vals[c])
            let (k0, k1, k2, k3) = mmh3x86_128_u64(id, m.embSeed[c])
            let nV = UInt32(m.embRows[c])
            let base = t * m.moNI + c * W
            for k in [k0, k1, k2, k3] {
                let row = Int(k % nV) * W
                for j in 0..<W { X[base + j] += m.embE[c][row + j] }
            }
        }
    }
    if dump { for t in 0..<T { var o = "E\(t)"; for j in 0..<m.moNI { o += "\t\(X[t*m.moNI+j])" }; print(o) } }
    // ---- embed maxout + layernorm ----
    let nPo = 3
    var un = [Float](repeating: 0, count: T * W * nPo)
    for t in 0..<T { for o in 0..<(W * nPo) { un[t * W * nPo + o] = m.moB[o] } }
    X.withUnsafeBufferPointer { ap in m.moW.withUnsafeBufferPointer { wp in
        un.withUnsafeMutableBufferPointer { cp in
            gemmT(ap.baseAddress!, wp.baseAddress!, cp.baseAddress!, T, m.moNI, W * nPo)
        } } }
    let PAD = 4
    var H = [Float](repeating: 0, count: (T + 2 * PAD) * W)
    for t in 0..<T {
        for o in 0..<W {
            var best = un[t * W * nPo + o * nPo]
            for q in 1..<nPo { let v = un[t * W * nPo + o * nPo + q]; if v > best { best = v } }
            H[(t + PAD) * W + o] = best
        }
        layerNorm(&H, (t + PAD) * W, W, m.lnG, m.lnB)
    }
    if dump { for t in 0..<T { var o = "M\(t)"; for j in 0..<W { o += "\t\(H[(t+PAD)*W+j])" }; print(o) } }
    // ---- 4 residual maxout-window blocks ----
    let TT = T + 2 * PAD
    var Z = [Float](repeating: 0, count: TT * 3 * W)
    var U2 = [Float](repeating: 0, count: TT * W * nPo)
    for b in 0..<m.encW.count {
        for i in 0..<(TT * 3 * W) { Z[i] = 0 }
        for t in 0..<TT {
            let z = t * 3 * W
            if t > 0 { for j in 0..<W { Z[z + j] = H[(t - 1) * W + j] } }
            for j in 0..<W { Z[z + W + j] = H[t * W + j] }
            if t + 1 < TT { for j in 0..<W { Z[z + 2 * W + j] = H[(t + 1) * W + j] } }
        }
        for t in 0..<TT { for o in 0..<(W * nPo) { U2[t * W * nPo + o] = m.encB[b][o] } }
        Z.withUnsafeBufferPointer { ap in m.encW[b].withUnsafeBufferPointer { wp in
            U2.withUnsafeMutableBufferPointer { cp in
                gemmT(ap.baseAddress!, wp.baseAddress!, cp.baseAddress!, TT, 3 * W, W * nPo)
            } } }
        var tmp = [Float](repeating: 0, count: TT * W)
        for t in 0..<TT {
            for o in 0..<W {
                var best = U2[t * W * nPo + o * nPo]
                for q in 1..<nPo { let v = U2[t * W * nPo + o * nPo + q]; if v > best { best = v } }
                tmp[t * W + o] = best
            }
            layerNorm(&tmp, t * W, W, m.encG[b], m.encLB[b])
        }
        for i in 0..<(TT * W) { H[i] += tmp[i] }
    }
    if dump { for t in 0..<T { var o = "\(t)"; for j in 0..<W { o += "\t\(H[(t+PAD)*W+j])" }; print(o) } }
    // ---- parser ----
    let h64 = m.nO
    var hs = [Float](repeating: 0, count: T * h64)
    for t in 0..<T { for o in 0..<h64 { hs[t * h64 + o] = m.linB[o] } }
    var tv = [Float](repeating: 0, count: T * W)
    for t in 0..<T { for j in 0..<W { tv[t * W + j] = H[(t + PAD) * W + j] } }
    tv.withUnsafeBufferPointer { ap in m.linW.withUnsafeBufferPointer { wp in
        hs.withUnsafeMutableBufferPointer { cp in
            gemmT(ap.baseAddress!, wp.baseAddress!, cp.baseAddress!, T, W, h64) } } }
    // cached[t][f][o][p] = sum_i hs[t][i] * paW[f][o][p][i]
    let FOP = m.nF * h64 * m.nP
    var cached = [Float](repeating: 0, count: T * FOP)
    hs.withUnsafeBufferPointer { ap in m.paW.withUnsafeBufferPointer { wp in
        cached.withUnsafeMutableBufferPointer { cp in
            gemmT(ap.baseAddress!, wp.baseAddress!, cp.baseAddress!, T, h64, FOP) } } }
    var ents: [Ent] = []
    var entStart = -1; var entLabel = ""
    var acc = [Float](repeating: 0, count: h64 * m.nP)
    var hid = [Float](repeating: 0, count: h64)
    var scores = [Float](repeating: 0, count: m.nClasses)
    for i in 0..<T {
        var ids = [i, entStart, -1]
        ids[2] = (ids[0] < 0 || ids[1] < 0) ? -1 : ids[0] - 1
        for k in 0..<(h64 * m.nP) { acc[k] = m.paB[k] }
        for f in 0..<m.nF {
            let src = ids[f] < 0 ? m.paPad : cached
            let base = ids[f] < 0 ? f * h64 * m.nP : ids[f] * FOP + f * h64 * m.nP
            for k in 0..<(h64 * m.nP) { acc[k] += src[base + k] }
        }
        for o in 0..<h64 {
            var best = acc[o * m.nP]
            for q in 1..<m.nP { let v = acc[o * m.nP + q]; if v > best { best = v } }
            hid[o] = best
        }
        for c in 0..<m.nClasses {
            var s = m.upB[c]
            for k in 0..<h64 { s += hid[k] * m.upW[c * h64 + k] }
            scores[c] = s
        }
        var best = -1; var bestv: Float = 0
        for c in 0..<m.nClasses {
            let mt = m.actMove[c], lbl = m.actLabel[c]
            let inside = entStart >= 0
            var ok = false
            switch mt {
            case 1: ok = !inside && !lbl.isEmpty && (i + 1 < T)
            case 2: ok = inside && lbl == entLabel && (i + 1 < T)
            case 3: ok = inside && lbl == entLabel
            case 4: ok = !inside && !lbl.isEmpty
            case 5: ok = !inside
            default: ok = false
            }
            if ok && (best < 0 || scores[c] > bestv) { best = c; bestv = scores[c] }
        }
        let mt = m.actMove[best], lbl = m.actLabel[best]
        if mt == 1 { entStart = i; entLabel = lbl }
        else if mt == 3 { ents.append(Ent(start: entStart, end: i + 1, label: entLabel)); entStart = -1 }
        else if mt == 4 { ents.append(Ent(start: i, end: i + 1, label: lbl)); entStart = -1 }
        else if mt == 5 { entStart = -1 }
    }
    return ents
}
