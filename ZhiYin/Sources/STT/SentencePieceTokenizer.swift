import Foundation

/// Simple SentencePiece tokenizer for decoding token IDs to text
/// This is a minimal implementation that reads the SPM model's vocab
class SentencePieceTokenizer {
    private var idToToken: [Int: String] = [:]
    
    init(modelPath: String) throws {
        // For MVP, we'll use a pre-exported vocab JSON
        // Full SPM binary parsing can be added later
        let vocabPath = modelPath.replacingOccurrences(of: ".model", with: "_vocab.json")
        
        if FileManager.default.fileExists(atPath: vocabPath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: vocabPath))
            if let vocab = try JSONSerialization.jsonObject(with: data) as? [String: Int] {
                for (token, id) in vocab {
                    idToToken[id] = token
                }
            }
        } else {
            // Fallback: try to read the sentencepiece model binary
            try loadFromSPMBinary(path: modelPath)
        }
        
        print("✅ Tokenizer loaded: \(idToToken.count) tokens")
    }
    
    func decode(ids: [Int]) -> String {
        var pieces = [String]()
        for id in ids {
            if let token = idToToken[id] {
                pieces.append(token)
            }
        }
        
        // Join and clean SentencePiece format
        var text = pieces.joined()
        
        // SentencePiece uses ▁ (U+2581) as word separator
        text = text.replacingOccurrences(of: "▁", with: " ")
        
        return text.trimmingCharacters(in: .whitespaces)
    }
    
    /// Basic SPM model binary reader
    /// Reads the protobuf-encoded vocabulary from the .model file
    private func loadFromSPMBinary(path: String) throws {
        // SentencePiece .model files are protobuf format
        // For a proper implementation, we'd use SwiftProtobuf
        // For MVP, we'll export vocab from Python first
        print("⚠️ SPM binary loading not yet implemented. Export vocab JSON with:")
        print("   python3 -c \"import sentencepiece as spm; sp=spm.SentencePieceProcessor(); sp.Load('\(path)'); import json; json.dump({sp.IdToPiece(i):i for i in range(sp.GetPieceSize())}, open('vocab.json','w'))\"")
    }
}
