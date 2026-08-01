// Bytecode compiler and backtracking VM.
//
// Replaces the continuation-passing matcher, whose recursion depth grew with
// the *input* length: one nested frame pair per repetition iteration, ~2.7 KB
// each. `a+` died at ~2-4k characters even on the main thread's 8 MB stack, and
// at ~400 characters on the 512 KB stacks that Swift concurrency's cooperative
// pool and swift-testing's runner hand out. For a library that scans arbitrary
// documents that is a denial of service on untrusted input.
//
// Here backtrack state lives in a heap array instead, so depth is bounded by
// memory rather than by the stack. The only remaining recursion is one level per
// *nested lookaround*, which is a property of the pattern (1-2) and never of the
// input.
//
// Semantics are those of the matcher this replaces, which is differentially
// verified against Python's `regex` module. Where that matcher deviates from
// textbook regex behaviour, the deviation is reproduced deliberately and marked.

/// A compiled instruction.
enum Inst {
    case char(UInt32, ignoreCase: Bool)
    case cls(Int, ignoreCase: Bool)      // index into `classes`
    case any(dotAll: Bool)
    /// Try `first`; on failure resume at `second`. Priority is what makes
    /// matching leftmost-first, like Python, rather than leftmost-longest.
    case split(Int, Int)
    case jmp(Int)
    /// Write the current position into a slot, undoably.
    case save(Int)
    /// Record the loop-entry position so the body can be checked for progress.
    case setMark(Int)
    /// Fail unless the position advanced since `setMark`.
    case progress(Int)
    case wordBoundary(Bool)
    case bol
    case eol
    case inputStart
    case inputEnd
    case backref(Int, ignoreCase: Bool)
    /// A sub-program invocation. `width` is the fixed lookbehind width.
    case look(entry: Int, ahead: Bool, positive: Bool, width: Int)
    case match
}

/// A compiled pattern: instructions, the character classes they reference, and
/// how many slots the VM needs.
struct Program {
    var insts: [Inst] = []
    var classes: [CharClass] = []
    var captureCount = 0
    var markCount = 0

    var captureSlots: Int { (captureCount + 1) * 2 }
    var slotCount: Int { captureSlots + markCount }
}

struct Compiler {
    var program = Program()
    private let dotAll: Bool
    private let multiline: Bool

    init(captureCount: Int, dotAll: Bool, multiline: Bool) {
        self.dotAll = dotAll
        self.multiline = multiline
        program.captureCount = captureCount
    }

    private mutating func emit(_ inst: Inst) -> Int {
        program.insts.append(inst)
        return program.insts.count - 1
    }

    private mutating func newMark() -> Int {
        let slot = program.captureSlots + program.markCount
        program.markCount += 1
        return slot
    }

    /// Compile `root` into a complete program ending in `.match`.
    ///
    /// `ignoreCase` is the pattern-level flag, which Presidio sets on every
    /// pattern. It seeds the compile-time fold and `(?i)` groups widen it
    /// further; folding at compile time means the VM never checks a flag.
    static func compile(
        _ root: Node, captureCount: Int,
        ignoreCase: Bool, dotAll: Bool, multiline: Bool
    ) -> Program {
        var compiler = Compiler(
            captureCount: captureCount, dotAll: dotAll, multiline: multiline
        )
        // Group 0 brackets the whole match.
        _ = compiler.emit(.save(0))
        compiler.compileNode(root, ignoreCase: ignoreCase)
        _ = compiler.emit(.save(1))
        _ = compiler.emit(.match)
        return compiler.program
    }

    private mutating func compileNode(_ node: Node, ignoreCase: Bool) {
        switch node {
        case .empty:
            break

        case .lit(let scalar):
            _ = emit(.char(scalar, ignoreCase: ignoreCase))

        case .cls(let characterClass):
            program.classes.append(characterClass)
            _ = emit(.cls(program.classes.count - 1, ignoreCase: ignoreCase))

        case .any:
            _ = emit(.any(dotAll: dotAll))

        case .concat(let children):
            for child in children { compileNode(child, ignoreCase: ignoreCase) }

        case .alt(let branches):
            compileAlternation(branches, ignoreCase: ignoreCase)

        case .group(let child, let capture):
            guard let capture else {
                compileNode(child, ignoreCase: ignoreCase)
                return
            }
            _ = emit(.save(capture * 2))
            compileNode(child, ignoreCase: ignoreCase)
            _ = emit(.save(capture * 2 + 1))

        case .rep(let child, let low, let high, let greedy):
            compileRepeat(child, low, high, greedy, ignoreCase: ignoreCase)

        case .look(let child, let ahead, let positive, let width):
            // Layout:
            //     look(entry: body)     <- on success, falls through to
            //     jmp(after)               this, which skips the body
            //   body: <child>; match
            //   after:
            // The jump is essential: without it, a successful lookaround would
            // fall straight into its own body and match it for real.
            let lookIndex = emit(.look(entry: 0, ahead: ahead, positive: positive, width: width))
            let skip = emit(.jmp(0))
            let bodyStart = program.insts.count
            compileNode(child, ignoreCase: ignoreCase)
            _ = emit(.match)
            let after = program.insts.count
            program.insts[lookIndex] = .look(
                entry: bodyStart, ahead: ahead, positive: positive, width: width
            )
            program.insts[skip] = .jmp(after)

        case .backref(let group):
            _ = emit(.backref(group, ignoreCase: ignoreCase))

        case .wordB(let want):
            _ = emit(.wordBoundary(want))

        case .bol:
            _ = emit(.bol)

        case .eol:
            _ = emit(.eol)

        case .inputStart:
            _ = emit(.inputStart)

        case .inputEnd:
            _ = emit(.inputEnd)

        case .caseToggle(let child, let ignore):
            // `(?i)` applies lexically, so fold it into the instructions at
            // compile time rather than tracking a flag at run time.
            compileNode(child, ignoreCase: ignore || ignoreCase)
        }
    }

    private mutating func compileAlternation(_ branches: [Node], ignoreCase: Bool) {
        guard !branches.isEmpty else { return }
        guard branches.count > 1 else {
            compileNode(branches[0], ignoreCase: ignoreCase)
            return
        }
        var exitJumps: [Int] = []
        for (index, branch) in branches.enumerated() {
            if index == branches.count - 1 {
                compileNode(branch, ignoreCase: ignoreCase)
            } else {
                let split = emit(.split(0, 0))
                let bodyStart = program.insts.count
                compileNode(branch, ignoreCase: ignoreCase)
                exitJumps.append(emit(.jmp(0)))
                program.insts[split] = .split(bodyStart, program.insts.count)
            }
        }
        let end = program.insts.count
        for jump in exitJumps { program.insts[jump] = .jmp(end) }
    }

    private mutating func compileRepeat(
        _ child: Node, _ low: Int, _ high: Int, _ greedy: Bool, ignoreCase: Bool
    ) {
        // Mandatory iterations. Each carries a progress check because the
        // matcher this replaces failed a zero-width mandatory iteration
        // (`e == i ? false : ...`) rather than accepting it. Textbook regex
        // would accept it; the differential corpus validates this behaviour, so
        // it is reproduced rather than "fixed".
        for _ in 0..<max(low, 0) {
            let mark = newMark()
            _ = emit(.setMark(mark))
            compileNode(child, ignoreCase: ignoreCase)
            _ = emit(.progress(mark))
        }

        if high == Int.max {
            // Unbounded tail: a loop, so program size stays constant.
            let mark = newMark()
            let loopStart = emit(.setMark(mark))
            let split = emit(.split(0, 0))
            let bodyStart = program.insts.count
            compileNode(child, ignoreCase: ignoreCase)
            _ = emit(.progress(mark))
            _ = emit(.jmp(loopStart))
            let end = program.insts.count
            program.insts[split] = greedy
                ? .split(bodyStart, end)
                : .split(end, bodyStart)
        } else {
            // Bounded tail: expand. Measured across every pattern this package
            // compiles, the largest upper bound is 63 and total expansion is
            // ~1,987 instructions, so this is cheaper than counter machinery.
            let optional = max(high - max(low, 0), 0)
            var pending: [(split: Int, body: Int)] = []
            for _ in 0..<optional {
                let split = emit(.split(0, 0))
                let bodyStart = program.insts.count
                let mark = newMark()
                _ = emit(.setMark(mark))
                compileNode(child, ignoreCase: ignoreCase)
                _ = emit(.progress(mark))
                pending.append((split, bodyStart))
            }
            let end = program.insts.count
            for (split, body) in pending {
                program.insts[split] = greedy
                    ? .split(body, end)
                    : .split(end, body)
            }
        }
    }
}
