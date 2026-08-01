/// Backtracking VM over a compiled `Program`.
///
/// Backtrack state is an explicit heap array, so match depth is bounded by
/// memory rather than by the thread's stack. The only recursion is one level per
/// nested lookaround — a property of the pattern, never of the input.
struct VM {
    let program: Program
    let input: [UInt32]
    let multiline: Bool

    /// Capture and mark slots. Captures are `-1` until written.
    var slots: [Int]
    /// Undo log of `(slot, previousValue)`, unwound on backtrack. Cheaper than
    /// snapshotting every slot into each stack frame.
    private var undo: [(slot: Int, value: Int)] = []

    private struct Frame {
        let pc: Int
        let sp: Int
        let undoCount: Int
    }

    init(program: Program, input: [UInt32], multiline: Bool) {
        self.program = program
        self.input = input
        self.multiline = multiline
        self.slots = [Int](repeating: -1, count: max(program.slotCount, 2))
    }

    @inline(__always)
    private mutating func write(_ slot: Int, _ value: Int) {
        undo.append((slot, slots[slot]))
        slots[slot] = value
    }

    @inline(__always)
    private mutating func unwind(to count: Int) {
        while undo.count > count {
            let entry = undo.removeLast()
            slots[entry.slot] = entry.value
        }
    }

    @inline(__always)
    private func isWord(_ index: Int) -> Bool {
        index >= 0 && index < input.count && UnicodeTables.isWord(input[index])
    }

    /// Run from `entry` at `start`. Returns the end position, or nil.
    ///
    /// `stopAt` is used by lookbehind, which must not merely match but must end
    /// exactly where the lookbehind was anchored.
    /// Clear state between start positions without reallocating.
    mutating func reset() {
        for index in slots.indices { slots[index] = -1 }
        undo.removeAll(keepingCapacity: true)
    }

    mutating func run(entry: Int, start: Int, stopAt: Int? = nil) -> Int? {
        var stack: [Frame] = []
        stack.reserveCapacity(64)
        var pc = entry
        var sp = start

        while true {
            var failed = false

            step: switch program.insts[pc] {
            case .char(let scalar, let ignoreCase):
                guard sp < input.count else { failed = true; break step }
                if input[sp] == scalar {
                    pc += 1; sp += 1
                } else if ignoreCase, Fold.equalIgnoringCase(input[sp], scalar) {
                    pc += 1; sp += 1
                } else {
                    failed = true
                }

            case .cls(let index, let ignoreCase):
                guard sp < input.count,
                      program.classes[index].matches(input[sp], ignoreCase: ignoreCase)
                else { failed = true; break step }
                pc += 1; sp += 1

            case .any(let dotAll):
                guard sp < input.count else { failed = true; break step }
                if !dotAll && input[sp] == 10 { failed = true; break step }
                pc += 1; sp += 1

            case .split(let first, let second):
                stack.append(Frame(pc: second, sp: sp, undoCount: undo.count))
                pc = first

            case .jmp(let target):
                pc = target

            case .save(let slot):
                write(slot, sp)
                pc += 1

            case .setMark(let slot):
                write(slot, sp)
                pc += 1

            case .progress(let slot):
                // A zero-width iteration fails the path, matching the matcher
                // this replaces.
                if slots[slot] == sp { failed = true } else { pc += 1 }

            case .wordBoundary(let want):
                if (isWord(sp - 1) != isWord(sp)) == want { pc += 1 } else { failed = true }

            case .bol:
                if sp == 0 || (multiline && input[sp - 1] == 10) { pc += 1 }
                else { failed = true }

            case .eol:
                // The third clause lets `$` match before a trailing newline even
                // without MULTILINE, which is what Python does.
                if sp == input.count
                    || (multiline && input[sp] == 10)
                    || (sp == input.count - 1 && input[sp] == 10) {
                    pc += 1
                } else { failed = true }

            case .inputStart:
                if sp == 0 { pc += 1 } else { failed = true }

            case .inputEnd:
                if sp == input.count { pc += 1 } else { failed = true }

            case .backref(let group, let ignoreCase):
                let from = slots[group * 2], to = slots[group * 2 + 1]
                if from < 0 {
                    // An unparticipating group matches empty, as in Python.
                    pc += 1
                    break step
                }
                let length = to - from
                guard sp + length <= input.count else { failed = true; break step }
                var matched = true
                for offset in 0..<length where input[sp + offset] != input[from + offset] {
                    if ignoreCase,
                       Fold.equalIgnoringCase(input[sp + offset], input[from + offset]) {
                        continue
                    }
                    matched = false
                    break
                }
                if matched { pc += 1; sp += length } else { failed = true }

            case .look(let lookEntry, let ahead, let positive, let width):
                // Recurse on self rather than copying the VM: a struct copy
                // here duplicates the program, the input and every slot, on
                // every lookaround evaluation. Recursion depth is the pattern's
                // lookaround nesting (1-2), never the input length.
                let undoBefore = undo.count
                var hit = false
                if ahead {
                    hit = run(entry: lookEntry, start: sp) != nil
                } else {
                    let from = sp - width
                    hit = from >= 0
                        && run(entry: lookEntry, start: from, stopAt: sp) != nil
                }
                if hit == positive {
                    // Captures set inside a *successful positive* lookaround
                    // persist, as they do in Python. Everything else leaves no
                    // trace.
                    if !positive { unwind(to: undoBefore) }
                    pc += 1
                } else {
                    unwind(to: undoBefore)
                    failed = true
                }

            case .match:
                if let stopAt, sp != stopAt { failed = true; break step }
                return sp
            }

            if failed {
                guard let frame = stack.popLast() else { return nil }
                unwind(to: frame.undoCount)
                pc = frame.pc
                sp = frame.sp
            }
        }
    }
}
