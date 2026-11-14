import Foundation

/// Splits streamed reply text into speakable sentences so speech starts before the reply ends.
struct SentenceChunker {
    /// Avoids speaking fragments like "Dr." or "1." on their own.
    var minimumLength = 12
    private var buffer = ""

    mutating func append(_ delta: String) -> [String] {
        buffer += delta
        var sentences: [String] = []
        while let cut = nextBoundary() {
            let sentence = String(buffer[..<cut])
            buffer = String(buffer[cut...])
            if let cleaned = Self.clean(sentence) { sentences.append(cleaned) }
        }
        return sentences
    }

    mutating func flush() -> String? {
        defer { buffer = "" }
        return Self.clean(buffer)
    }

    private func nextBoundary() -> String.Index? {
        var index = buffer.startIndex
        var length = 0
        while index < buffer.endIndex {
            let character = buffer[index]
            let next = buffer.index(after: index)
            length += 1
            if character == "\n", length > 1 { return next }
            if ".!?".contains(character), next < buffer.endIndex, buffer[next].isWhitespace, length >= minimumLength {
                return next
            }
            index = next
        }
        return nil
    }

    /// Strips Markdown symbols that a TTS voice would read aloud.
    static func clean(_ text: String) -> String? {
        let stripped = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "* ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard stripped.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return stripped
    }
}
