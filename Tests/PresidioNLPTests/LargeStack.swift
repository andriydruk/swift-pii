import Foundation

/// Runs `body` on a thread with a large stack.
///
/// `PureRegex` is a recursive CPS backtracker, and its recursion depth grows
/// with the length of the text being matched. Measured on the tokenizer's
/// 15 KB infix pattern: texts of ~400 characters need **more than 512 KB** of
/// stack — 512 KB crashes with SIGBUS, 1 MB survives.
///
/// 512 KB is exactly what secondary threads get by default, including
/// swift-testing's runner and Swift concurrency's cooperative pool. So this is
/// not a test-only concern: a caller invoking the tokenizer or any recognizer
/// from a `Task` can take down the process on ordinary input.
///
/// Using a big stack here keeps the suite honest — it tests real behaviour
/// rather than crashing — but it does not fix the underlying limitation. See
/// docs/decisions/0001-regex-backend.md; the explicit-stack rewrite is the M5
/// fix, and it addresses throughput at the same time.
func withLargeStack<T>(
    _ megabytes: Int = 64,
    _ body: @escaping @Sendable () throws -> T
) throws -> T {
    nonisolated(unsafe) var result: Result<T, Error>?
    let finished = DispatchSemaphore(value: 0)

    let thread = Thread {
        result = Result { try body() }
        finished.signal()
    }
    thread.stackSize = megabytes * 1024 * 1024
    thread.start()
    finished.wait()

    switch result! {
    case .success(let value): return value
    case .failure(let error): throw error
    }
}
