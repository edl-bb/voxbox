import XCTest

@testable import voxbox

final class SpokenNumbersTests: XCTestCase {

    private func render(_ text: String) -> String { SpokenNumbers.render(in: text) }

    func testMoneyPercentAndPlainNumbers() {
        XCTAssertEqual(
            render("I think it was twelve thousand five hundred dollars, into the tracker."),
            "I think it was $12,500, into the tracker.")
        XCTAssertEqual(render("they were like two hundred bucks cheaper"), "they were like $200 cheaper")
        XCTAssertEqual(render("Twenty percent off until Friday"), "20% off until Friday")
        XCTAssertEqual(render("about fifteen per cent of users"), "about 15% of users")
        XCTAssertEqual(render("one hundred and five people came"), "105 people came")
        XCTAssertEqual(render("forty-two answers"), "42 answers")
        XCTAssertEqual(render("two point five million dollars"), "$2,500,000")
        XCTAssertEqual(render("three pounds fifty"), "£3 fifty")
        XCTAssertEqual(render("fifty cents"), "50 cents")
        XCTAssertEqual(render("move the retro to two pm"), "move the retro to 2pm")
        XCTAssertEqual(render("one dollar"), "$1")
    }

    func testDecimalsAndLargeValues() {
        XCTAssertEqual(SpokenNumbers.parse(["two", "point", "five"]), Decimal(string: "2.5"))
        XCTAssertEqual(SpokenNumbers.parse(["twelve", "thousand", "five", "hundred"]), 12_500)
        XCTAssertEqual(SpokenNumbers.parse(["one", "million", "two", "hundred", "thousand"]), 1_200_000)
        XCTAssertEqual(SpokenNumbers.grouped(1_234_567), "1,234,567")
        XCTAssertEqual(SpokenNumbers.grouped(Decimal(string: "12.5")!), "12.5")
        XCTAssertEqual(render("two point five million"), "2,500,000")
        XCTAssertEqual(render("it scored two point five"), "it scored 2.5")
    }

    func testLoneSmallNumbersAreLeftAsSpoken() {
        XCTAssertEqual(render("one of the reasons"), "one of the reasons")
        XCTAssertEqual(render("two people came"), "two people came")
        XCTAssertEqual(render("the second slide"), "the second slide")
        XCTAssertEqual(render("give me a hundred"), "give me 100", "a scale word is a real number")
    }

    func testAmbiguousRunsAreLeftAlone() {
        XCTAssertEqual(render("back in twenty twenty six"), "back in twenty twenty six")
        XCTAssertEqual(render("dial one two three"), "dial one two three")
        XCTAssertEqual(render("ten five"), "ten five")
    }

    func testEmailsAndDigitsAreUntouched() {
        XCTAssertEqual(render("send it to jules@testco.com by Thursday at 2pm"), "send it to jules@testco.com by Thursday at 2pm")
        XCTAssertEqual(render("it cost $12,500 already"), "it cost $12,500 already")
    }

    func testPostPassRendersNumeralsOnlyWhenAsked() {
        let text = "the total was twelve thousand five hundred dollars"
        XCTAssertEqual(
            CleanupPostPass.tidy(text, reference: text, markdownAllowed: false, numerals: true),
            "The total was $12,500")
        XCTAssertEqual(
            CleanupPostPass.tidy(text, reference: text, markdownAllowed: false),
            "The total was twelve thousand five hundred dollars")
        XCTAssertTrue(CleanupPromptSet.compiled.rendersNumerals(.lightCleanup))
        XCTAssertTrue(CleanupPromptSet.compiled.rendersNumerals(.polish))
        XCTAssertFalse(CleanupPromptSet.compiled.rendersNumerals(.formatting))
        XCTAssertFalse(CleanupPromptSet.compiled.rendersNumerals(.custom))
    }
}
