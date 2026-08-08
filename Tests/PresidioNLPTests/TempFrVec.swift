import Testing
import Foundation
@testable import PresidioNLP

struct TempFrVec {
    @Test func dumpVectors() throws {
        guard let dir = modelDirectory("fr") else { return }
        let model = try NERModel(dir: dir)
        let tokenizer = try SpacyTokenizer.french()
        let text = "M. Pierre-Yves Le Gall enseigne à l'université de Lyon."
        let tokens = tokenizer.tokenize(text)
        _ = runNER(model, tokens.map(\.text), tokens.map(\.norm), dump: true)
    }
}
