import XCTest

@testable import voxbox

final class LocalBPETokenizerTests: XCTestCase {

    /// A toy tokenizer.json in the Hugging Face layout: byte-mapped vocab,
    /// ranked merges, a Split pre-tokenizer and one special token.
    private static let toy = """
        {
          "added_tokens": [{"id": 10, "content": "<|end|>", "special": true}],
          "pre_tokenizer": {
            "type": "Sequence",
            "pretokenizers": [
              {"type": "Split", "pattern": {"Regex": "'s|'t|'re|'ve|'m|'ll|'d| ?\\\\p{L}+| ?\\\\p{N}+| ?[^\\\\s\\\\p{L}\\\\p{N}]+|\\\\s+(?!\\\\S)|\\\\s+"}, "behavior": "Isolated", "invert": false},
              {"type": "ByteLevel", "add_prefix_space": false, "trim_offsets": true, "use_regex": false}
            ]
          },
          "model": {
            "type": "BPE",
            "ignore_merges": false,
            "vocab": {"h": 0, "e": 1, "l": 2, "o": 3, "he": 4, "ll": 5, "hell": 6, "Ġ": 7, "Ġw": 8, "w": 9, "<|end|>": 10, "Ã": 11, "©": 12},
            "merges": ["h e", "l l", "he ll", "Ġ w"]
          }
        }
        """

    private func tokenizer() throws -> LocalBPETokenizer {
        try LocalBPETokenizer(tokenizerJSON: Data(Self.toy.utf8))
    }

    func testByteMappingRoundTrips() {
        XCTAssertEqual(LocalBPETokenizer.byteMapped(" w"), "Ġw")
        XCTAssertEqual(LocalBPETokenizer.byteMapped("é"), "Ã©")
        XCTAssertEqual(LocalBPETokenizer.byteUnmapped("Ã©"), "é")
        for byte in 0..<256 {
            let char = LocalBPETokenizer.byteToChar[byte]
            XCTAssertEqual(LocalBPETokenizer.charToByte[char], UInt8(byte))
        }
        XCTAssertEqual(Set(LocalBPETokenizer.byteToChar).count, 256, "mapping is a bijection")
    }

    func testMergesFollowRankOrder() throws {
        let bpe = try tokenizer()
        XCTAssertEqual(bpe.merge("hello"), ["hell", "o"])
        XCTAssertEqual(bpe.merge("Ġw"), ["Ġw"])
        XCTAssertEqual(bpe.merge("ol"), ["o", "l"], "no merge listed, stays apart")
    }

    func testEncodeSplitsThenMerges() throws {
        let bpe = try tokenizer()
        XCTAssertEqual(bpe.pieces(of: "hello w"), ["hello", " w"])
        XCTAssertEqual(bpe.encode("hello w"), [6, 3, 8])
        XCTAssertEqual(bpe.encode("é"), [11, 12])
        XCTAssertEqual(bpe.encode(""), [])
    }

    func testDecodeReversesEncode() throws {
        let bpe = try tokenizer()
        XCTAssertEqual(bpe.decode([6, 3, 8]), "hello w")
        XCTAssertEqual(bpe.decode([11, 12]), "é")
        XCTAssertEqual(bpe.decode([999]), "", "unknown ids are skipped")
    }

    func testIgnoreMergesUsesWholePieceWhenInVocab() throws {
        let json = Self.toy.replacingOccurrences(of: "\"ignore_merges\": false", with: "\"ignore_merges\": true")
            .replacingOccurrences(of: "\"©\": 12}", with: "\"©\": 12, \"hello\": 13}")
        let bpe = try LocalBPETokenizer(tokenizerJSON: Data(json.utf8))
        XCTAssertEqual(bpe.encode("hello"), [13])
    }

    func testMergesAsPairsAreAccepted() throws {
        let json = Self.toy.replacingOccurrences(
            of: "\"merges\": [\"h e\", \"l l\", \"he ll\", \"Ġ w\"]",
            with: "\"merges\": [[\"h\", \"e\"], [\"l\", \"l\"], [\"he\", \"ll\"], [\"Ġ\", \"w\"]]")
        let bpe = try LocalBPETokenizer(tokenizerJSON: Data(json.utf8))
        XCTAssertEqual(bpe.encode("hello"), [6, 3])
    }

    func testFallsBackToGPT2PatternWithoutASplitPreTokenizer() throws {
        let json = Self.toy.replacingOccurrences(of: "\"pre_tokenizer\": {", with: "\"pre_tokenizer_unused\": {")
        let bpe = try LocalBPETokenizer(tokenizerJSON: Data(json.utf8))
        XCTAssertEqual(bpe.pieces(of: "hello w"), ["hello", " w"])
    }

    func testRejectsNonBPEModels() {
        let json = Self.toy.replacingOccurrences(of: "\"type\": \"BPE\"", with: "\"type\": \"Unigram\"")
        XCTAssertThrowsError(try LocalBPETokenizer(tokenizerJSON: Data(json.utf8))) { error in
            XCTAssertEqual(error as? LocalBPETokenizer.LoadError, .unsupportedModel("Unigram"))
        }
    }

    // MARK: - Added tokens

    func testAddedTokenTableSplitsSpecialsOut() throws {
        let table = try AddedTokenTable(tokenizerJSON: Data(Self.toy.utf8))
        XCTAssertEqual(table.idsByContent["<|end|>"], 10)
        XCTAssertEqual(
            table.split("hello<|end|> w<|end|>"),
            [.text("hello"), .special(10), .text(" w"), .special(10)])
        XCTAssertEqual(table.split("plain"), [.text("plain")])
        XCTAssertEqual(table.split(""), [])
    }

    func testLongestSpecialWinsWhenOneIsAPrefixOfAnother() {
        let table = AddedTokenTable(tokens: [("<|im_start|>", 1), ("<|im_start|>assistant", 2)])
        XCTAssertEqual(table.split("<|im_start|>assistant hi"), [.special(2), .text(" hi")])
        XCTAssertEqual(table.split("<|im_start|>user"), [.special(1), .text("user")])
    }
}
