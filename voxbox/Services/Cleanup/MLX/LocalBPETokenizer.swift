import Foundation

/// Byte-level BPE as described by a Hugging Face `tokenizer.json`: the scheme
/// Llama 3 and Qwen share (GPT-2 byte mapping, a Split pre-tokenizer regex,
/// ranked merges). Self-contained so the tokenizer is not hostage to
/// whichever swift-transformers version WhisperKit pins, and so token ids can
/// be checked in tests.
nonisolated final class LocalBPETokenizer: @unchecked Sendable {
    enum LoadError: Error, Equatable {
        case unreadable
        case unsupportedModel(String)
    }

    let vocab: [String: Int]
    let inverseVocab: [Int: String]
    /// `left + "\u{0}" + right` → merge priority (lower merges first).
    private let mergeRanks: [String: Int]
    private let splitRegex: NSRegularExpression?
    /// Llama 3 sets `ignore_merges`: a piece that is itself in the vocab is
    /// emitted as one token without running merges.
    private let ignoreMerges: Bool
    private var cache: [String: [Int]] = [:]
    private let lock = NSLock()

    /// GPT-2's fallback when a tokenizer.json has no Split pre-tokenizer.
    static let gpt2Pattern = #"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"#

    convenience init(directory: URL) throws {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("tokenizer.json")) else {
            throw LoadError.unreadable
        }
        try self.init(tokenizerJSON: data)
    }

    init(tokenizerJSON data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let model = root["model"] as? [String: Any]
        else { throw LoadError.unreadable }
        let type = model["type"] as? String ?? ""
        guard type == "BPE" else { throw LoadError.unsupportedModel(type) }

        var vocab: [String: Int] = [:]
        if let raw = model["vocab"] as? [String: Any] {
            vocab.reserveCapacity(raw.count)
            for (token, value) in raw {
                if let id = value as? Int { vocab[token] = id }
            }
        }
        self.vocab = vocab
        var inverse: [Int: String] = [:]
        inverse.reserveCapacity(vocab.count)
        for (token, id) in vocab { inverse[id] = token }
        self.inverseVocab = inverse

        var ranks: [String: Int] = [:]
        if let merges = model["merges"] as? [Any] {
            ranks.reserveCapacity(merges.count)
            for (rank, entry) in merges.enumerated() {
                if let pair = entry as? [String], pair.count == 2 {
                    ranks[pair[0] + "\u{0}" + pair[1]] = rank
                } else if let line = entry as? String, let space = line.firstIndex(of: " ") {
                    ranks[String(line[..<space]) + "\u{0}" + String(line[line.index(after: space)...])] = rank
                }
            }
        }
        self.mergeRanks = ranks
        self.ignoreMerges = model["ignore_merges"] as? Bool ?? false

        let pattern = Self.splitPattern(in: root["pre_tokenizer"]) ?? Self.gpt2Pattern
        self.splitRegex = try? NSRegularExpression(pattern: pattern)
    }

    /// The Split regex from a `Sequence` or bare `Split` pre-tokenizer.
    static func splitPattern(in preTokenizer: Any?) -> String? {
        guard let node = preTokenizer as? [String: Any] else { return nil }
        if node["type"] as? String == "Split", let pattern = node["pattern"] as? [String: Any] {
            return pattern["Regex"] as? String
        }
        if let children = node["pretokenizers"] as? [Any] {
            for child in children {
                if let found = splitPattern(in: child) { return found }
            }
        }
        return nil
    }

    // MARK: - Byte mapping

    /// GPT-2's printable stand-ins for the 256 byte values.
    static let byteToChar: [Character] = {
        var bytes: [Int] = Array(0x21...0x7E) + Array(0xA1...0xAC) + Array(0xAE...0xFF)
        var chars = bytes
        var next = 0
        for value in 0..<256 where !bytes.contains(value) {
            bytes.append(value)
            chars.append(256 + next)
            next += 1
        }
        var table = [Character](repeating: " ", count: 256)
        for (byte, char) in zip(bytes, chars) {
            table[byte] = Character(Unicode.Scalar(char)!)
        }
        return table
    }()

    static let charToByte: [Character: UInt8] = {
        var table: [Character: UInt8] = [:]
        for (byte, char) in byteToChar.enumerated() { table[char] = UInt8(byte) }
        return table
    }()

    static func byteMapped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for byte in text.utf8 { out.append(byteToChar[Int(byte)]) }
        return out
    }

    static func byteUnmapped(_ mapped: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(mapped.count)
        for char in mapped {
            if let byte = charToByte[char] { bytes.append(byte) } else { bytes.append(contentsOf: Array(String(char).utf8)) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Encode / decode

    /// Plain text only: callers split out special tokens first.
    func encode(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        var ids: [Int] = []
        for piece in pieces(of: text) {
            ids.append(contentsOf: encodePiece(piece))
        }
        return ids
    }

    func decode(_ ids: [Int]) -> String {
        var mapped = ""
        for id in ids {
            if let token = inverseVocab[id] { mapped += token }
        }
        return Self.byteUnmapped(mapped)
    }

    func id(for token: String) -> Int? { vocab[token] }
    func token(for id: Int) -> String? { inverseVocab[id] }

    func pieces(of text: String) -> [String] {
        guard let splitRegex else { return [text] }
        let ns = text as NSString
        return splitRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range)
        }
    }

    private func encodePiece(_ piece: String) -> [Int] {
        lock.lock()
        if let cached = cache[piece] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let mapped = Self.byteMapped(piece)
        let ids: [Int]
        if ignoreMerges, let whole = vocab[mapped] {
            ids = [whole]
        } else {
            ids = merge(mapped).compactMap { vocab[$0] }
        }

        lock.lock()
        if cache.count > 20_000 { cache.removeAll(keepingCapacity: true) }
        cache[piece] = ids
        lock.unlock()
        return ids
    }

    /// Standard BPE: repeatedly merge the lowest-ranked adjacent pair.
    func merge(_ mapped: String) -> [String] {
        var symbols = mapped.unicodeScalars.map { String($0) }
        while symbols.count > 1 {
            var best: (rank: Int, index: Int)?
            for index in 0..<(symbols.count - 1) {
                if let rank = mergeRanks[symbols[index] + "\u{0}" + symbols[index + 1]],
                    rank < (best?.rank ?? Int.max)
                {
                    best = (rank, index)
                }
            }
            guard let best else { break }
            let left = symbols[best.index]
            let right = symbols[best.index + 1]
            var next: [String] = []
            next.reserveCapacity(symbols.count)
            var index = 0
            while index < symbols.count {
                if index < symbols.count - 1, symbols[index] == left, symbols[index + 1] == right {
                    next.append(left + right)
                    index += 2
                } else {
                    next.append(symbols[index])
                    index += 1
                }
            }
            symbols = next
        }
        return symbols
    }
}

/// `added_tokens` from `tokenizer.json`: the special tokens (headers,
/// end-of-turn) that the BPE model does not know about.
nonisolated struct AddedTokenTable: Sendable {
    let idsByContent: [String: Int]
    let contentByID: [Int: String]
    private let pattern: String?

    init(directory: URL) throws {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("tokenizer.json")) else {
            throw LocalBPETokenizer.LoadError.unreadable
        }
        try self.init(tokenizerJSON: data)
    }

    init(tokenizerJSON data: Data) throws {
        struct File: Decodable {
            struct Added: Decodable {
                let id: Int
                let content: String
            }
            let added_tokens: [Added]?
        }
        let added = (try? JSONDecoder().decode(File.self, from: data))?.added_tokens ?? []
        self.init(tokens: added.map { ($0.content, $0.id) })
    }

    init(tokens: [(content: String, id: Int)]) {
        var byContent: [String: Int] = [:]
        var byID: [Int: String] = [:]
        for (content, id) in tokens {
            byContent[content] = id
            byID[id] = content
        }
        idsByContent = byContent
        contentByID = byID
        let sorted = byContent.keys.sorted { $0.count > $1.count }
        pattern = sorted.isEmpty ? nil : sorted.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    }

    enum Segment: Equatable {
        case text(String)
        case special(Int)
    }

    /// Splits text so special tokens map to their ids and the rest goes to
    /// the BPE model.
    func split(_ text: String) -> [Segment] {
        guard let pattern, let regex = try? NSRegularExpression(pattern: pattern) else {
            return text.isEmpty ? [] : [.text(text)]
        }
        let ns = text as NSString
        var segments: [Segment] = []
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                segments.append(.text(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            }
            if let id = idsByContent[ns.substring(with: match.range)] {
                segments.append(.special(id))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            segments.append(.text(ns.substring(from: cursor)))
        }
        return segments
    }
}
