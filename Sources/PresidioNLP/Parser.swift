// spaCy v3's arc-eager dependency parser, in pure Swift.
//
// It is here for one reason, and it is not syntax. spaCy's NER refuses to open
// or extend an entity when the next token starts a sentence, and those
// boundaries come from this component. Without it the port reproduces spaCy's
// NER *with the parser excluded* -- exactly, in eight languages, but that is
// not the same pipeline anyone runs. The heads and labels fall out on the way
// and are exposed because they are free once the transitions are right, and
// because they are what makes a boundary divergence attributable.
//
// The network is the same TransitionBasedParser as NER: a precomputable affine
// over a hidden projection of the token vectors, then a linear upper layer over
// the maxout. Two things differ. It reads eight state features rather than
// three, and it listens to the pipeline's *shared* tok2vec rather than carrying
// its own -- which is why `Tok2Vec` was factored out of the tagger.
//
// Ported from spacy/pipeline/_parser_internals/{_state.pxd,arc_eager.pyx},
// spacy/ml/parser_model.pyx and spacy/tokens/doc.pyx, rather than from memory.

import Foundation

/// A parsed sentence structure: what the parser predicts, plus the one thing
/// downstream actually consumes.
public struct DependencyParse: Sendable {
    /// Head token index per token. A root is its own head, which is how spaCy
    /// stores it too (a relative head offset of zero).
    public let heads: [Int]
    /// Dependency label per token; `"ROOT"` for roots.
    public let deps: [String]
    /// Token indices that begin a sentence.
    ///
    /// Not predicted directly. spaCy derives it from the tree: every root
    /// contributes the left edge of its subtree. So a boundary is only ever as
    /// right as the heads that imply it.
    public let sentenceStarts: Set<Int>
}

// The five arc-eager move types, in the order `arc_eager.pyx` enumerates them.
// That order is also the order the serialized moves table uses, so these are
// the integers read straight out of the model.
private let SHIFT = 0
private let REDUCE = 1
private let LEFT = 2
private let RIGHT = 3
private let BREAK = 4

/// `subtok` is the one label whose validity is per-label rather than per-move,
/// because it may only join adjacent tokens. English `sm` is trained with
/// `learn_tokens: false` so it has no such transitions, but the rule is cheap
/// and its absence would be silent.
private let subtokLabel = "subtok"

/// spaCy's `StateC`: the arc-eager configuration.
///
/// Stack, buffer and arcs, plus the three flags that make this system
/// non-monotonic: which tokens have been pushed back and may not be shifted
/// again, which tokens have been declared sentence starts, and the heads
/// assigned so far.
private struct ArcEagerState {
    struct Arc { var head: Int; var child: Int; var label: Int }

    let length: Int
    /// `sent_start` as preset on the document, *not* what this state has
    /// decided. 1 means "is a sentence start", -1 means "may not be one".
    /// spaCy's `Doc` marks token 0 with a 1 the moment it is built, which is
    /// load-bearing: it stops token 0 from being shifted or attached if it is
    /// ever pushed back onto the buffer.
    let preset: [Int8]

    var stack: [Int] = []
    var rebuffer: [Int] = []
    var heads: [Int]
    var unshiftable: [Bool]
    var sentStarts: Set<Int> = []
    var leftArcs: [Int: [Arc]] = [:]
    var rightArcs: [Int: [Arc]] = [:]
    var bufferIndex = 0

    init(length: Int) {
        self.length = length
        var preset = [Int8](repeating: 0, count: length)
        if length > 0 { preset[0] = 1 }
        self.preset = preset
        self.heads = [Int](repeating: -1, count: length)
        self.unshiftable = [Bool](repeating: false, count: length)
    }

    // --- accessors ------------------------------------------------------

    func S(_ i: Int) -> Int {
        guard i >= 0, i < stack.count else { return -1 }
        return stack[stack.count - (i + 1)]
    }

    func B(_ i: Int) -> Int {
        guard i >= 0 else { return -1 }
        if i < rebuffer.count { return rebuffer[rebuffer.count - (i + 1)] }
        let index = bufferIndex + (i - rebuffer.count)
        return index >= length ? -1 : index
    }

    var stackDepth: Int { stack.count }
    var bufferLength: Int { (length - bufferIndex) + rebuffer.count }
    var isFinal: Bool { stackDepth <= 0 && bufferLength == 0 }

    func hasHead(_ child: Int) -> Bool {
        child >= 0 && child < length && heads[child] >= 0
    }

    func head(of child: Int) -> Int {
        (child < 0 || child >= length) ? -1 : heads[child]
    }

    func isSentStart(_ word: Int) -> Bool {
        guard word >= 0, word < length else { return false }
        return preset[word] == 1 || sentStarts.contains(word)
    }

    func cannotSentStart(_ word: Int) -> Bool {
        guard word >= 0, word < length else { return false }
        return preset[word] == -1
    }

    func isUnshiftable(_ item: Int) -> Bool {
        item >= 0 && item < length && unshiftable[item]
    }

    /// The `idx`-th child of `head`, counting from the most recently added.
    ///
    /// Deleted arcs are tombstoned with `child == -1` rather than removed, and
    /// are skipped here — see `deleteArc` for why they exist at all.
    private func nthChild(_ arcs: [Int: [Arc]], _ head: Int, _ idx: Int) -> Int {
        guard idx >= 1, let list = arcs[head] else { return -1 }
        var seen = 0
        for arc in list.reversed() where arc.child != -1 {
            seen += 1
            if seen == idx { return arc.child }
        }
        return -1
    }

    func L(_ head: Int, _ idx: Int) -> Int { nthChild(leftArcs, head, idx) }
    func R(_ head: Int, _ idx: Int) -> Int { nthChild(rightArcs, head, idx) }

    /// The eight feature tokens the parser scores a state from.
    ///
    /// `set_context_tokens(ids, 8)` in `_state.pxd`. Note that only the first
    /// left child of B(0) is read, and only the first left and right child of
    /// S(0) — the thirteen-feature variant reads more, and this model is not
    /// built with it.
    func contextTokens() -> [Int] {
        [B(0), B(1), S(0), S(1), S(2), L(B(0), 1), L(S(0), 1), R(S(0), 1)]
    }

    // --- mutation -------------------------------------------------------

    mutating func push() {
        let b0: Int
        if let last = rebuffer.last {
            b0 = last
            rebuffer.removeLast()
        } else {
            b0 = bufferIndex
            bufferIndex += 1
        }
        stack.append(b0)
    }

    mutating func pop() { stack.removeLast() }

    mutating func unshift() {
        let s0 = stack[stack.count - 1]
        unshiftable[s0] = true
        rebuffer.append(s0)
        stack.removeLast()
    }

    mutating func setReshiftable(_ item: Int) {
        if item >= 0 && item < length { unshiftable[item] = false }
    }

    mutating func forceFinal() {
        stack.removeAll()
        bufferIndex = length
        rebuffer.removeAll()
    }

    mutating func addArc(head: Int, child: Int, label: Int) {
        if hasHead(child) { deleteArc(heads[child], child) }
        let arc = Arc(head: head, child: child, label: label)
        if head > child { leftArcs[head, default: []].append(arc) }
        else { rightArcs[head, default: []].append(arc) }
        heads[child] = head
    }

    /// Remove an arc — but only if it is the most recent one for that head.
    ///
    /// This mirrors `map_del_arc` exactly, including the part that does
    /// nothing. Upstream pops the arc when it is last in the head's list, and
    /// otherwise walks the list assigning `-1` to a *copy* of the arc: Cython
    /// infers a value type there, so the write never reaches the vector and the
    /// stale arc survives. Reproduced rather than corrected, because those
    /// stale arcs are visible to `L()` and `R()` and therefore feed the model.
    /// The authoritative head is `heads[child]`, which is always overwritten.
    private mutating func deleteArc(_ head: Int, _ child: Int) {
        if head > child { Self.popIfLast(&leftArcs, head, child) }
        else { Self.popIfLast(&rightArcs, head, child) }
    }

    private static func popIfLast(_ arcs: inout [Int: [Arc]], _ head: Int, _ child: Int) {
        guard var list = arcs[head], let last = list.last else { return }
        guard last.head == head, last.child == child else { return }
        list.removeLast()
        arcs[head] = list
    }
}

// --- the five transitions ----------------------------------------------
//
// `is_valid` only; the cost functions are the training oracle and have no
// bearing on inference.

private func isValid(move: Int, label: String, _ st: ArcEagerState) -> Bool {
    switch move {
    case SHIFT:
        if st.stackDepth == 0 { return true }
        if st.bufferLength < 2 { return false }
        if st.isSentStart(st.B(0)) { return false }
        if st.isUnshiftable(st.B(0)) { return false }
        return true
    case REDUCE:
        if st.stackDepth == 0 { return false }
        if st.bufferLength == 0 { return true }
        // `l_edge` is the identity in `StateC`, so this reads B(0) directly.
        if st.stackDepth == 1 && st.cannotSentStart(st.B(0)) { return false }
        return true
    case LEFT, RIGHT:
        if st.stackDepth == 0 { return false }
        if st.bufferLength == 0 { return false }
        if st.isSentStart(st.B(0)) { return false }
        if label == subtokLabel && st.S(0) != st.B(0) - 1 { return false }
        return true
    case BREAK:
        if st.bufferLength < 2 { return false }
        if st.B(1) != st.B(0) + 1 { return false }
        if st.isSentStart(st.B(1)) { return false }
        if st.cannotSentStart(st.B(1)) { return false }
        return true
    default:
        return false
    }
}

private func apply(move: Int, label: Int, to st: inout ArcEagerState) {
    switch move {
    case SHIFT:
        st.push()
    case REDUCE:
        if st.hasHead(st.S(0)) || st.stackDepth == 1 { st.pop() } else { st.unshift() }
    case LEFT:
        st.addArc(head: st.B(0), child: st.S(0), label: label)
        // Changing the stack makes it safe to clear the shifted mark: the
        // configuration cannot repeat, so this cannot loop.
        st.setReshiftable(st.B(0))
        st.pop()
    case RIGHT:
        st.addArc(head: st.S(0), child: st.B(0), label: label)
        st.push()
    case BREAK:
        st.sentStarts.insert(st.B(1))
    default:
        break
    }
}

/// spaCy's dependency parser.
///
/// `@unchecked Sendable` on the same audited grounds as the other components:
/// every stored property is written during `init` and only read afterwards, and
/// `parse` allocates its own state per call.
public final class DependencyParser: @unchecked Sendable {

    public typealias LoadError = ComponentLoadError

    let tok2vec: Tok2Vec

    // Hidden projection of the token vectors, (nO, width).
    private var linW: [Float] = []
    private var linB: [Float] = []
    // Precomputable affine: (nF, nO, nP, nO), (nO, nP), (1, nF, nO, nP).
    private var paW: [Float] = []
    private var paB: [Float] = []
    private var paPad: [Float] = []
    // Upper layer, (nClasses, nO).
    private var upW: [Float] = []
    private var upB: [Float] = []

    private var nO = 64, nP = 2, nF = 8, nClasses = 0
    private var actMove: [Int] = []
    private var actLabel: [String] = []

    /// Number of transition classes the model was built with. 106 for English
    /// `sm`: two unlabelled moves, 47 left-arc labels, 56 right-arc labels, and
    /// `B-ROOT`.
    public var actionCount: Int { actMove.count }

    /// - Parameter directory: an unpacked spaCy model directory containing
    ///   `parser/`.
    public convenience init(directory: String) throws {
        try self.init(directory: directory, tok2vec: nil)
    }

    /// - Parameters:
    ///   - directory: an unpacked spaCy model directory containing `parser/`.
    ///   - tok2vec: the already-loaded shared encoder, when a caller has one.
    ///     The parser is a listener, so loading a second copy would be six
    ///     megabytes of duplicate weights for identical output. Internal
    ///     because `Tok2Vec` is an implementation detail of the pipeline, not
    ///     something a caller should have to assemble.
    init(directory: String, tok2vec: Tok2Vec?) throws {
        let modelPath = directory + "/parser/model"
        let movesPath = directory + "/parser/moves"
        for path in [modelPath, movesPath] where
            !FileManager.default.fileExists(atPath: path) {
            throw LoadError.missing(path)
        }

        self.tok2vec = try tok2vec ?? Tok2Vec(path: directory + "/tok2vec/model")

        var reader = MPReader(readFile(modelPath))
        let root = reader.value()
        guard let nodes = root.m("nodes")?.asArr,
              let params = root.m("params")?.asArr
        else { throw LoadError.malformed("parser/model is not a thinc model") }

        var linears: [(Int, Tensor, Tensor)] = []
        var affine = -1
        for i in 0..<nodes.count {
            switch nodes[i].m("name")?.asStr ?? "" {
            case "linear":
                guard let w = params[i].m("W").map(mpTensor),
                      let b = params[i].m("b").map(mpTensor)
                else { throw LoadError.malformed("linear node \(i) is incomplete") }
                linears.append((i, w, b))
            case "precomputable_affine":
                affine = i
            default:
                break
            }
        }

        // Two linears, told apart by how they compose rather than by their
        // literal English shapes — the hidden width is shared across the `sm`
        // models but the class count is not. Same reasoning as `NERModel`.
        guard linears.count >= 2 else {
            throw LoadError.malformed(
                "expected 2 linear layers in the parser, found \(linears.count)"
            )
        }
        var hidden = linears[0], upper = linears[1]
        if upper.1.shape.count < 2 || upper.1.shape[1] != hidden.1.shape[0] {
            swap(&hidden, &upper)
        }
        guard upper.1.shape.count == 2, hidden.1.shape.count == 2,
              upper.1.shape[1] == hidden.1.shape[0]
        else {
            throw LoadError.malformed(
                "parser linears do not compose: \(hidden.1.shape) then \(upper.1.shape)"
            )
        }
        linW = hidden.1.data
        linB = hidden.2.data
        upW = upper.1.data
        upB = upper.2.data
        nClasses = upper.1.shape[0]

        guard affine >= 0,
              let w = params[affine].m("W").map(mpTensor),
              let b = params[affine].m("b").map(mpTensor),
              let pad = params[affine].m("pad").map(mpTensor)
        else { throw LoadError.malformed("no precomputable_affine in parser/model") }
        paW = w.data
        paB = b.data
        paPad = pad.data
        nF = w.shape[0]
        nO = w.shape[1]
        nP = w.shape[2]
        guard nF == 8 else {
            // The 13-feature variant reads grandchildren, which
            // `contextTokens()` does not gather. Better to say so than to score
            // a state from the wrong tokens.
            throw LoadError.malformed(
                "parser reads \(nF) state features; only the 8-feature "
                + "configuration is implemented"
            )
        }
        guard nO == hidden.1.shape[0] else {
            throw LoadError.malformed(
                "hidden width \(hidden.1.shape[0]) disagrees with the affine's \(nO)"
            )
        }
        guard hidden.1.shape[1] == self.tok2vec.width else {
            throw LoadError.malformed(
                "parser hidden layer expects \(hidden.1.shape[1])-wide token "
                + "vectors, tok2vec produces \(self.tok2vec.width)"
            )
        }

        (actMove, actLabel) = loadTransitionMoves(movesPath)
        guard actMove.count == nClasses else {
            throw LoadError.malformed(
                "parser/moves has \(actMove.count) transitions for \(nClasses) classes"
            )
        }
    }

    /// Parse one document.
    ///
    /// `text` is needed only for the tok2vec's `SPACY` feature — whether each
    /// token is followed by whitespace.
    public func parse(tokens: [Token], text: String) -> DependencyParse {
        let count = tokens.count
        guard count > 0 else {
            return DependencyParse(heads: [], deps: [], sentenceStarts: [])
        }

        let scores = precomputeScores(tokens: tokens, text: text)
        var state = ArcEagerState(length: count)

        // spaCy has no step bound: the transition system provably terminates,
        // because Break can fire at most once per position, a pushed-back token
        // is unshiftable until an arc reshifts it, and every other move
        // consumes from the buffer. This bound exists so that a bug in *this*
        // port is a wrong answer rather than a hang. It has never fired on the
        // corpus; if it ever does, the parse is truncated exactly as spaCy
        // truncates one it cannot score.
        let maxSteps = 8 * count + 16
        var steps = 0
        var stateScores = [Float](repeating: 0, count: nClasses)

        while !state.isFinal {
            steps += 1
            if steps > maxSteps { state.forceFinal(); break }

            scores.score(state.contextTokens(), into: &stateScores)

            var best = -1
            for c in 0..<nClasses where isValid(
                move: actMove[c], label: actLabel[c], state
            ) {
                if best < 0 || stateScores[c] > stateScores[best] { best = c }
            }
            guard best >= 0 else { state.forceFinal(); break }
            apply(move: actMove[best], label: best, to: &state)
        }

        // `set_annotations`: an unattached token is its own head, and every
        // token that is its own head is labelled ROOT.
        var heads = [Int](repeating: 0, count: count)
        var deps = [String](repeating: "", count: count)
        for i in 0..<count {
            let head = state.heads[i]
            heads[i] = head < 0 ? i : head
            deps[i] = heads[i] == i ? "ROOT" : arcLabel(state, child: i)
        }

        var edges = leftAndRightEdges(heads: heads)
        deprojectivize(heads: &heads, deps: &deps, tokens: tokens, edges: edges)
        edges = leftAndRightEdges(heads: heads)

        var starts = Set<Int>()
        for i in 0..<count where heads[i] == i { starts.insert(edges.left[i]) }
        return DependencyParse(heads: heads, deps: deps, sentenceStarts: starts)
    }

    /// The label of the arc that gave `child` its head.
    ///
    /// The state stores the class index on the arc; only the winning arc for a
    /// child survives in `heads`, so this looks the arc up rather than tracking
    /// labels separately.
    private func arcLabel(_ state: ArcEagerState, child: Int) -> String {
        let head = state.heads[child]
        let arcs = head > child ? state.leftArcs[head] : state.rightArcs[head]
        guard let list = arcs else { return "dep" }
        for arc in list.reversed() where arc.child == child {
            return actLabel[arc.label]
        }
        return "dep"
    }

    // --- scoring ---------------------------------------------------------

    /// The per-token half of the network, computed once and then indexed by
    /// state features. This is the whole point of a *precomputable* affine:
    /// a document of N tokens is parsed in ~2N states, and without this the
    /// same token vectors would be projected over and over.
    private struct PrecomputedScores {
        let cached: [Float]
        let pad: [Float]
        let bias: [Float]
        let upperW: [Float]
        let upperB: [Float]
        let nF: Int, nO: Int, nP: Int, nClasses: Int

        func score(_ ids: [Int], into out: inout [Float]) {
            let stride = nO * nP
            var acc = [Float](repeating: 0, count: stride)
            for k in 0..<stride { acc[k] = bias[k] }
            for f in 0..<nF {
                let id = ids[f]
                if id < 0 {
                    let base = f * stride
                    for k in 0..<stride { acc[k] += pad[base + k] }
                } else {
                    let base = id * nF * stride + f * stride
                    for k in 0..<stride { acc[k] += cached[base + k] }
                }
            }
            var hid = [Float](repeating: 0, count: nO)
            for o in 0..<nO {
                var best = acc[o * nP]
                for q in 1..<nP where acc[o * nP + q] > best { best = acc[o * nP + q] }
                hid[o] = best
            }
            for c in 0..<nClasses {
                var sum = upperB[c]
                let row = c * nO
                for k in 0..<nO { sum += hid[k] * upperW[row + k] }
                out[c] = sum
            }
        }
    }

    private func precomputeScores(tokens: [Token], text: String) -> PrecomputedScores {
        let count = tokens.count
        let width = tok2vec.width
        let vectors = tok2vec.encode(tokens: tokens, text: text)

        var projected = [Float](repeating: 0, count: count * nO)
        for t in 0..<count {
            for o in 0..<nO { projected[t * nO + o] = linB[o] }
        }
        vectors.withUnsafeBufferPointer { input in
            linW.withUnsafeBufferPointer { weights in
                projected.withUnsafeMutableBufferPointer { output in
                    gemmT(input.baseAddress!, weights.baseAddress!,
                          output.baseAddress!, count, width, nO)
                }
            }
        }

        let featureStride = nF * nO * nP
        var cached = [Float](repeating: 0, count: count * featureStride)
        projected.withUnsafeBufferPointer { input in
            paW.withUnsafeBufferPointer { weights in
                cached.withUnsafeMutableBufferPointer { output in
                    gemmT(input.baseAddress!, weights.baseAddress!,
                          output.baseAddress!, count, nO, featureStride)
                }
            }
        }

        return PrecomputedScores(
            cached: cached, pad: paPad, bias: paB,
            upperW: upW, upperB: upB,
            nF: nF, nO: nO, nP: nP, nClasses: nClasses
        )
    }
}

// --- the tree, after the transitions ------------------------------------

/// `l_edge` and `r_edge`: the extent of each token's subtree.
///
/// A port of `_set_lr_kids_and_edges`, including its retry loop. One pass is
/// enough for a projective parse; a non-projective one needs the edges widened
/// repeatedly, and spaCy documents cases needing four. The loop stops when
/// every head lies inside its own sentence, or after eleven attempts — which is
/// spaCy's bound, and means a pathological tree yields *some* answer rather
/// than spinning.
private func leftAndRightEdges(heads: [Int]) -> (left: [Int], right: [Int]) {
    let count = heads.count
    var left = Array(0..<count)
    var right = Array(0..<count)
    var loopCount = 0
    var settled = false
    while !settled {
        for i in 0..<count {
            let head = heads[i]
            if left[i] < left[head] { left[head] = left[i] }
            if right[i] > right[head] { right[head] = right[i] }
        }
        for i in stride(from: count - 1, through: 0, by: -1) {
            let head = heads[i]
            if right[i] > right[head] { right[head] = right[i] }
            if left[i] < left[head] { left[head] = left[i] }
        }

        // Are all heads inside their own sentence yet?
        var starts = Set<Int>()
        for i in 0..<count where heads[i] == i { starts.insert(left[i]) }
        settled = true
        var sentenceStart = 0
        for i in 0..<count where (i > 0 && starts.contains(i)) || i == count - 1 {
            let sentenceEnd = i
            for j in sentenceStart..<sentenceEnd
            where heads[j] < sentenceStart || heads[j] > sentenceEnd {
                settled = false
                break
            }
            if !settled { break }
            sentenceStart = i
        }
        if loopCount > 10 { break }
        loopCount += 1
    }
    return (left, right)
}

/// Undo the pseudo-projective HEAD decoration of Nivre & Nilsson 2005.
///
/// The parser is trained on projectivized trees, so a non-projective arc is
/// learned as an arc to a nearer head carrying a decorated label `X||Y`. This
/// reattaches it: search the subtree under the current head, breadth-first and
/// left to right, for the first token labelled `Y`.
///
/// English `sm` has 26 such labels — `R-relcl||dobj`, `L-pobj||prep` and so on
/// — so this is not a rare path. It runs against edges computed *before* the
/// loop and heads mutated *during* it, which is what spaCy does; recomputing
/// the edges as it goes would be a different traversal.
private func deprojectivize(
    heads: inout [Int], deps: inout [String], tokens: [Token],
    edges: (left: [Int], right: [Int])
) {
    let count = heads.count
    let isSpace = tokens.map { token in
        !token.text.isEmpty
            && token.text.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
    }

    /// Children of `token`, left then right, each ascending — `Token.children`.
    func children(of token: Int) -> [Int] {
        var out: [Int] = []
        var i = edges.left[token]
        while i < token {
            if heads[i] == token { out.append(i) }
            i += 1
        }
        i = token + 1
        while i <= edges.right[token] {
            if heads[i] == token { out.append(i) }
            i += 1
        }
        return out
    }

    for i in 0..<count {
        guard let range = deps[i].range(of: "||") else { continue }
        let newLabel = String(deps[i][deps[i].startIndex..<range.lowerBound])
        let headLabel = String(deps[i][range.upperBound...])

        var newHead = heads[i]
        var queue = [heads[i]]
        // spaCy's breadth-first search has no visit set and no depth bound. It
        // relies on the tree being a tree; this bound is the same insurance as
        // the step bound in `parse`, and equally has never fired.
        var levels = 0
        search: while !queue.isEmpty && levels <= count {
            var next: [Int] = []
            for parent in queue {
                for child in children(of: parent) {
                    if isSpace[child] || child == i { continue }
                    if deps[child] == headLabel { newHead = child; break search }
                    next.append(child)
                }
            }
            queue = next
            levels += 1
        }

        heads[i] = newHead
        deps[i] = newLabel
    }
}

/// The transition table from a component's `moves` file.
///
/// msgpack wrapping a JSON string of `{moveType: {label: frequency}}`. Class
/// order is the order that structure enumerates — move types ascending, labels
/// in insertion order within each — which is why this reads the JSON rather
/// than sorting anything. Both the NER's BILUO system and the parser's
/// arc-eager one serialize this way, so both read it here.
func loadTransitionMoves(_ path: String) -> (move: [Int], label: [String]) {
    let bytes = readFile(path)
    guard !bytes.isEmpty else { return ([], []) }
    var reader = MPReader(bytes)
    guard let json = reader.value().m("moves")?.asStr else { return ([], []) }

    var move: [Int] = []
    var label: [String] = []
    var depth = 0
    var key = ""
    var pending = ""
    var readingString = false
    var moveType = -1
    for character in json {
        if readingString {
            if character == "\"" { readingString = false; key = pending }
            else { pending.append(character) }
            continue
        }
        switch character {
        case "\"":
            readingString = true
            pending = ""
        case "{":
            depth += 1
            if depth == 2 { moveType = Int(key) ?? moveType }
        case "}":
            depth -= 1
        case ":" where depth == 2:
            move.append(moveType)
            label.append(key)
        default:
            break
        }
    }
    return (move, label)
}
