import XCTest

@testable import speaktype

final class AustralianEnglishSpellingTests: XCTestCase {

    // MARK: - Language code plumbing

    func testEngineLanguageCollapsesAustralianEnglishToEnglish() {
        XCTAssertEqual(AustralianEnglishSpelling.engineLanguage(for: "en-AU"), "en")
        XCTAssertEqual(AustralianEnglishSpelling.engineLanguage(for: "en-au"), "en")
    }

    func testEngineLanguagePassesOtherCodesThrough() {
        XCTAssertEqual(AustralianEnglishSpelling.engineLanguage(for: "en"), "en")
        XCTAssertEqual(AustralianEnglishSpelling.engineLanguage(for: "auto"), "auto")
        XCTAssertEqual(AustralianEnglishSpelling.engineLanguage(for: "hi"), "hi")
    }

    func testIsAustralianEnglish() {
        XCTAssertTrue(AustralianEnglishSpelling.isAustralianEnglish("en-AU"))
        XCTAssertTrue(AustralianEnglishSpelling.isAustralianEnglish("EN-au"))
        XCTAssertFalse(AustralianEnglishSpelling.isAustralianEnglish("en"))
    }

    // MARK: - Core spelling families

    func testIzeFamilyBecomesIse() {
        XCTAssertEqual(
            AustralianEnglishSpelling.apply(to: "Please organize the organization."),
            "Please organise the organisation.")
        XCTAssertEqual(
            AustralianEnglishSpelling.apply(to: "I realized we should prioritize optimizing it."),
            "I realised we should prioritise optimising it.")
    }

    func testYzeFamilyBecomesYse() {
        XCTAssertEqual(
            AustralianEnglishSpelling.apply(to: "Analyze the data she analyzed."),
            "Analyse the data she analysed.")
    }

    func testOrFamilyBecomesOur() {
        XCTAssertEqual(
            AustralianEnglishSpelling.apply(to: "My favorite color has a nice flavor."),
            "My favourite colour has a nice flavour.")
        XCTAssertEqual(
            AustralianEnglishSpelling.apply(to: "Their behavior honored the neighborhood."),
            "Their behaviour honoured the neighbourhood.")
    }

    func testErToReAndConsonantFamilies() {
        XCTAssertEqual(
            AustralianEnglishSpelling.apply(to: "The center is two kilometers from the theater."),
            "The centre is two kilometres from the theatre.")
        XCTAssertEqual(
            AustralianEnglishSpelling.apply(to: "She canceled while traveling."),
            "She cancelled while travelling.")
    }

    func testMiscellaneousWords() {
        XCTAssertEqual(
            AustralianEnglishSpelling.apply(to: "The gray airplane used aluminum for defense."),
            "The grey aeroplane used aluminium for defence.")
    }

    // MARK: - Words that must NOT change

    func testDropsUBeforeOusStaysAmericanStyle() {
        // Australian English keeps -or- in these derived forms.
        XCTAssertEqual(AustralianEnglishSpelling.apply(to: "a humorous, vigorous, glamorous laboratory"),
                       "a humorous, vigorous, glamorous laboratory")
        XCTAssertEqual(AustralianEnglishSpelling.apply(to: "an honorary degree"), "an honorary degree")
    }

    func testAmbiguousAndUnrelatedWordsUntouched() {
        XCTAssertEqual(AustralianEnglishSpelling.apply(to: "the size of the prize"), "the size of the prize")
        XCTAssertEqual(AustralianEnglishSpelling.apply(to: "seize the horizon"), "seize the horizon")
        XCTAssertEqual(AustralianEnglishSpelling.apply(to: "program the meter"), "program the meter")
    }

    // MARK: - Case preservation

    func testPreservesCapitalisation() {
        XCTAssertEqual(AustralianEnglishSpelling.apply(to: "Color COLOR color"), "Colour COLOUR colour")
        XCTAssertEqual(AustralianEnglishSpelling.apply(to: "Organize This"), "Organise This")
    }

    func testPreservesPunctuationAndSpacing() {
        XCTAssertEqual(
            AustralianEnglishSpelling.apply(to: "color, color; (color)!"),
            "colour, colour; (colour)!")
        XCTAssertEqual(AustralianEnglishSpelling.apply(to: ""), "")
    }

    func testEmailAndUrlLikeTokensSurvive() {
        // Words inside URLs/emails are letter-runs bounded by punctuation, so a
        // mapped word could change — but the common case of full addresses with
        // unmapped words must pass through byte-for-byte.
        XCTAssertEqual(
            AustralianEnglishSpelling.apply(to: "mail me at sam@example.com today"),
            "mail me at sam@example.com today")
    }
}
