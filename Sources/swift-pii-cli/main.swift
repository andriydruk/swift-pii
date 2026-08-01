import Foundation
import PresidioCLI

// Thin: everything testable lives in PresidioCLI.
exit(CommandLineTool().run(Array(CommandLine.arguments.dropFirst())))
