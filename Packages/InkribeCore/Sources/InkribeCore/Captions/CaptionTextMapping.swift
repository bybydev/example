import Foundation
import NaturalLanguage

/// Existing timed text only; correction never creates IDs or timestamps.
public struct CaptionTextUnit: Sendable {
    public let id: UUID
    public let text: String
    public init(id: UUID, text: String) { self.id = id; self.text = text }
}

public enum CaptionTextMapping {
    private struct Token {
        let text: String
        let start: Int
    }

    public static func isSingleWord(_ text: String) -> Bool {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            count += 1
            return count < 2
        }
        return count == 1
    }

    /// Use the typing session's original units, including across intermediate
    /// clears. Equal-size word replacements retain their existing timing slots;
    /// extra words share a slot and remain a phrase, rather than invented timing.
    public static func correctedText(_ value: String, units: [CaptionTextUnit]) -> [UUID: String] {
        guard let fallback = units.first?.id else { return [:] }
        var old: [Character] = [], owners: [UUID] = []
        for unit in units {
            let characters = Array(unit.text)
            old.append(contentsOf: characters)
            owners.append(contentsOf: repeatElement(unit.id, count: characters.count))
        }
        var leading: [(Character, UUID)] = [], trailing: [(Character, UUID)] = []
        while old.first?.isWhitespace == true { leading.append((old.removeFirst(), owners.removeFirst())) }
        while old.last?.isWhitespace == true { trailing.append((old.removeLast(), owners.removeLast())) }
        let next = Array(value.trimmingCharacters(in: .whitespacesAndNewlines))
        let originalTokens = tokens(String(old)), nextTokens = tokens(String(next))
        var tokenOwners: [UUID] = []
        for index in originalTokens.indices {
            let end = index + 1 < originalTokens.count ? originalTokens[index + 1].start : old.count
            // Separators belong to their existing unit. A lexical word must not
            // cross units or share its unit with another lexical word.
            let start = originalTokens[index].start
            let lexicalCount = originalTokens[index].text.count
            let ids = Set(owners[start..<min(end, start + lexicalCount)])
            guard let id = ids.first, ids.count == 1 else {
                return characterCorrection(old: old, owners: owners, next: next, fallback: fallback,
                    leading: leading, trailing: trailing, units: units)
            }
            tokenOwners.append(id)
        }
        guard !originalTokens.isEmpty, !nextTokens.isEmpty,
              Set(tokenOwners).count == tokenOwners.count else {
            return characterCorrection(old: old, owners: owners, next: next, fallback: fallback,
                leading: leading, trailing: trailing, units: units)
        }

        let difference = nextTokens.map(\.text).difference(from: originalTokens.map(\.text))
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var anchors: [(old: Int, next: Int)] = [(-1, -1)]
        var a = 0, b = 0
        while a < originalTokens.count && b < nextTokens.count {
            if removed.contains(a) { a += 1 }
            else if inserted.contains(b) { b += 1 }
            else { anchors.append((a, b)); a += 1; b += 1 }
        }
        anchors.append((originalTokens.count, nextTokens.count))
        var assignments = [UUID](repeating: fallback, count: nextTokens.count)
        for index in 1..<anchors.count {
            let before = anchors[index - 1], after = anchors[index]
            if after.next < nextTokens.count { assignments[after.next] = tokenOwners[after.old] }
            let oldRange = (before.old + 1)..<after.old
            let newRange = (before.next + 1)..<after.next
            if oldRange.count == newRange.count {
                for (oldIndex, newIndex) in zip(oldRange, newRange) { assignments[newIndex] = tokenOwners[oldIndex] }
            } else {
                let owner: UUID
                if !oldRange.isEmpty { owner = tokenOwners[oldRange.lowerBound] }
                else if after.old < tokenOwners.count { owner = tokenOwners[after.old] }
                else if before.old >= 0 { owner = tokenOwners[before.old] }
                else { owner = fallback }
                for newIndex in newRange { assignments[newIndex] = owner }
            }
        }
        var result = emptyText(units)
        for (character, owner) in leading { result[owner, default: ""].append(character) }
        for index in nextTokens.indices {
            let start = index == 0 ? 0 : nextTokens[index].start
            let end = index + 1 < nextTokens.count ? nextTokens[index + 1].start : next.count
            result[assignments[index], default: ""] += String(next[start..<end])
        }
        for (character, owner) in trailing.reversed() { result[owner, default: ""].append(character) }
        return result
    }

    private static func tokens(_ text: String) -> [Token] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        let offsets = Dictionary(uniqueKeysWithValues: text.indices.enumerated().map { ($0.element, $0.offset) })
        var result: [Token] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if let start = offsets[range.lowerBound] { result.append(Token(text: String(text[range]), start: start)) }
            return true
        }
        return result
    }

    private static func emptyText(_ units: [CaptionTextUnit]) -> [UUID: String] {
        Dictionary(units.map { ($0.id, "") }, uniquingKeysWith: { first, _ in first })
    }

    private static func characterCorrection(old: [Character], owners: [UUID], next: [Character], fallback: UUID,
                                            leading: [(Character, UUID)], trailing: [(Character, UUID)],
                                            units: [CaptionTextUnit]) -> [UUID: String] {
        var prefix = 0
        while prefix < min(old.count, next.count), old[prefix] == next[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count - prefix, next.count - prefix),
              old[old.count - suffix - 1] == next[next.count - suffix - 1] { suffix += 1 }
        let insertionOwner = owners.isEmpty ? fallback : owners[min(prefix, owners.count - 1)]
        let newOwners = Array(owners.prefix(prefix)) +
            Array(repeating: insertionOwner, count: next.count - prefix - suffix) + Array(owners.suffix(suffix))
        var result = emptyText(units)
        for (character, owner) in leading { result[owner, default: ""].append(character) }
        for (character, owner) in zip(next, newOwners) { result[owner, default: ""].append(character) }
        for (character, owner) in trailing.reversed() { result[owner, default: ""].append(character) }
        return result
    }
}
