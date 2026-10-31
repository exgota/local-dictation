import Foundation

/// Joins overlapping model windows at agreeing words near the middle of their overlap.
public struct TranscriptOverlapMerger: Sendable {
    public struct Token: Sendable {
        public let piece: String
        public let start: TimeInterval
        public let end: TimeInterval

        public init(piece: String, start: TimeInterval, end: TimeInterval) {
            self.piece = piece
            self.start = start
            self.end = end
        }
    }

    private struct Word: Sendable {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
        var key: String {
            String(text.lowercased().unicodeScalars.filter {
                (97...122).contains($0.value) || (48...57).contains($0.value) || $0.value == 39
            })
        }
    }

    private var words: [Word] = []
    public init() {}
    public var text: String { words.map(\.text).joined(separator: " ") }

    /// Returns false without changing the transcript if timings cannot support a safe splice.
    @discardableResult
    public mutating func append(text: String, tokens: [Token]?, windowStart: TimeInterval) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        guard let tokens, !tokens.isEmpty, windowStart.isFinite else { return false }
        var following: [Word] = []
        var current: Word?
        var previousStart = -TimeInterval.infinity
        for token in tokens {
            guard token.start.isFinite, token.end.isFinite, token.end >= token.start,
                  token.start + 0.000_001 >= previousStart else { return false }
            previousStart = token.start
            let piece = TranscriptUnknownMarker.remove(fromPiece: token.piece).replacingOccurrences(of: "▁", with: " ")
            guard !piece.isEmpty else { continue }
            // Split embedded boundaries too, including one introduced by an unknown marker.
            let parts = piece.split(separator: " ", omittingEmptySubsequences: false)
            for (index, part) in parts.enumerated() {
                if index > 0 || current == nil {
                    if let word = current, !word.text.isEmpty { following.append(word) }
                    current = Word(text: "", start: token.start, end: token.end)
                }
                current?.text += part
                current?.end = token.end
            }
        }
        if let current, !current.text.isEmpty { following.append(current) }
        guard !following.isEmpty else { return false }
        let reconstructed = following.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let expected = TranscriptUnknownMarker.remove(from: text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard reconstructed == expected else { return false }
        guard !words.isEmpty else { words = following; return true }
        let overlapEnd = words.last!.end
        let leftFirst = words.firstIndex { $0.end >= windowStart } ?? words.count
        let left = Array(words[leftFirst...])
        let rightLast = following.firstIndex { $0.start > overlapEnd + 0.5 } ?? following.count
        let right = Array(following[..<rightLast])
        let middle = (windowStart + overlapEnd) / 2
        var best: (score: Double, left: Int, right: Int)?
        for block in Self.matchingBlocks(left.map(\.key), right.map(\.key)) {
            for offset in 0..<block.count {
                var leftIndex = block.left + offset
                var rightIndex = block.right + offset
                if block.count == 1 {
                    // Sequence matching alone chooses the first identical word. In a run of repeated words, use the
                    // closest pair in time so a later occurrence cannot replace an earlier spoken repetition.
                    let key = left[leftIndex].key
                    var leftFirst = leftIndex, leftLast = leftIndex
                    var rightFirst = rightIndex, rightLast = rightIndex
                    while leftFirst > 0 && left[leftFirst - 1].key == key { leftFirst -= 1 }
                    while leftLast + 1 < left.count && left[leftLast + 1].key == key { leftLast += 1 }
                    while rightFirst > 0 && right[rightFirst - 1].key == key { rightFirst -= 1 }
                    while rightLast + 1 < right.count && right[rightLast + 1].key == key { rightLast += 1 }
                    var difference = abs(left[leftIndex].start - right[rightIndex].start)
                    for candidateLeft in leftFirst...leftLast {
                        for candidateRight in rightFirst...rightLast {
                            let candidateDifference = abs(left[candidateLeft].start - right[candidateRight].start)
                            if candidateDifference < difference {
                                difference = candidateDifference
                                leftIndex = candidateLeft
                                rightIndex = candidateRight
                            }
                        }
                    }
                }
                let time = left[leftIndex].start
                let score = abs(time - middle) - 0.05 * Double(min(block.count, 6))
                if abs(time - right[rightIndex].start) < 0.6 && (best == nil || score < best!.score) {
                    best = (score, leftIndex, rightIndex)
                }
            }
        }
        if let best {
            words = Array(words[..<(leftFirst + best.left)]) + following[best.right...]
        } else {
            words = words.filter { $0.start < middle } + following.filter { $0.start >= middle }
        }
        return true
    }

    /// Equivalent to SequenceMatcher's ordered, longest contiguous matching blocks, without autojunk.
    private static func matchingBlocks(_ left: [String], _ right: [String]) -> [(left: Int, right: Int, count: Int)] {
        var ranges = [(0, left.count, 0, right.count)]
        var blocks: [(left: Int, right: Int, count: Int)] = []
        while let (leftStart, leftEnd, rightStart, rightEnd) = ranges.popLast() {
            var bestLeft = leftStart, bestRight = rightStart, bestCount = 0
            var lengths: [Int: Int] = [:]
            for i in leftStart..<leftEnd {
                var next: [Int: Int] = [:]
                for j in rightStart..<rightEnd where left[i] == right[j] {
                    let count = (lengths[j - 1] ?? 0) + 1
                    next[j] = count
                    if count > bestCount {
                        bestLeft = i - count + 1
                        bestRight = j - count + 1
                        bestCount = count
                    }
                }
                lengths = next
            }
            guard bestCount > 0 else { continue }
            blocks.append((bestLeft, bestRight, bestCount))
            if leftStart < bestLeft && rightStart < bestRight {
                ranges.append((leftStart, bestLeft, rightStart, bestRight))
            }
            let nextLeft = bestLeft + bestCount, nextRight = bestRight + bestCount
            if nextLeft < leftEnd && nextRight < rightEnd { ranges.append((nextLeft, leftEnd, nextRight, rightEnd)) }
        }
        blocks.sort { $0.left < $1.left || ($0.left == $1.left && $0.right < $1.right) }
        var joined: [(left: Int, right: Int, count: Int)] = []
        for block in blocks {
            if let last = joined.last, last.left + last.count == block.left, last.right + last.count == block.right {
                joined[joined.count - 1].count += block.count
            } else { joined.append(block) }
        }
        return joined
    }
}
