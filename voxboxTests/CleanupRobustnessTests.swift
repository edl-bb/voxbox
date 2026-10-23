import XCTest

@testable import voxbox

/// Fixes that came out of the History-based cleanup eval (evals/cleanup).
/// `scripts/cleanup-eval.sh --self-test` runs the same checks without Xcode.
@MainActor
final class CleanupRobustnessTests: XCTestCase {

    func testSpokenListsBeyondBareOrdinals() {
        XCTAssertEqual(
            CleanupPostPass.formatSpokenLists(
                "Morning all, two things. Firstly, the venue is booked. And secondly, basically we still need a caterer. Cheers."),
            "Morning all, two things:\n\n1. The venue is booked.\n2. We still need a caterer.\n\nCheers.")
        XCTAssertEqual(
            CleanupPostPass.formatSpokenLists(
                "Quick notes. The first thing is the invoice went out. Then second, the client wants a call. And lastly, I'm off Friday."),
            "Quick notes:\n\n1. The invoice went out.\n2. The client wants a call.\n3. I'm off Friday.")
        let outOfOrder = "And second, I disagree. First, we never agreed."
        XCTAssertEqual(CleanupPostPass.formatSpokenLists(outOfOrder), outOfOrder)
        XCTAssertEqual(
            CleanupPostPass.stripSpokenFillers("And third, basically we need an owner. It's basically done."),
            "And third, we need an owner. It's basically done.")
    }

    func testPolishCannotDropDaysOrListItems() {
        XCTAssertEqual(
            CleanupGuardrail.alteredUnit(input: "they'll have options by Monday", output: "They'll have options by mon."), "date")
        XCTAssertEqual(
            CleanupGuardrail.alteredUnit(
                input: "Firstly, the page is live. And secondly, we need copy. And lastly, drinks Friday.",
                output: "Firstly, the page is live, and we need copy. And lastly, drinks Friday."),
            "spoken list")
        XCTAssertNil(
            CleanupGuardrail.alteredUnit(
                input: "Firstly, the page is live. Secondly, we need copy.",
                output: "First, the page is live. Second, we need copy."))
    }

    func testRoundThreeContentAndQuestions() {
        let decimals = [
            ("A p value of point oh four three.", "A p value of 0.043."),
            ("point zero zero five", "0.005"),
            ("It is two point oh five.", "It is 2.05."),
            ("It was zero point oh four.", "It was 0.04."),
            ("At point oh oh five.", "At 0.005."),
            ("Dial oh four one two two.", "Dial oh four one two two."),
            ("The turning point five years ago.", "The turning point five years ago."),
            ("The point of order.", "The point of order."),
            ("We are at point one in the agenda.", "We are at point one in the agenda."),
            ("Keep  ordinary spacing.", "Keep  ordinary spacing."),
        ]
        for (input, expected) in decimals {
            XCTAssertTrue(SpokenNumbers.render(in: input) == expected, input)
        }
        let repairs = [
            ("It was twelve kilos, no wait, fourteen kilos and we got nine.",
             "It was fourteen kilos and we got nine."),
            ("Use 12 kilos. No wait, 14 kilos.", "Use 14 kilos."),
            ("Use twelve kilos, no wait, fourteen.", "Use fourteen kilos."),
            ("It was twelve kilos. No worries, fourteen is fine.",
             "It was twelve kilos. No worries, fourteen is fine."),
            ("Use twelve kilos? No wait, fourteen kilos.",
             "Use twelve kilos? No wait, fourteen kilos."),
            ("Use twelve widgets, no wait, fourteen widgets.",
             "Use twelve widgets, no wait, fourteen widgets."),
        ]
        for (input, expected) in repairs {
            let output = SpokenRepairs.resolve(input)
            XCTAssertTrue(output == expected, input)
            XCTAssertTrue(SpokenRepairs.resolve(output) == output, "repair idempotence: \(input)")
        }
        let questions = [
            ("Hey can you explain clean_survey.py.", "Hey can you explain clean_survey.py?"),
            ("So what's the best way.", "So what's the best way?"),
            ("Anyway can we go.", "Anyway can we go?"),
            ("And can you check it.", "And can you check it?"),
            ("Is that the levy included.", "Is that the levy included?"),
            ("Is the bond two weeks rent", "Is the bond two weeks rent?"),
            ("Could our team do it.", "Could our team do it?"),
            ("Can you write it without.", "Can you write it without."),
            ("Can you write it without", "Can you write it without"),
            ("Can you write something that doesn't sound like.",
             "Can you write something that doesn't sound like."),
            ("What should we lead with given the", "What should we lead with given the"),
            ("I wonder if the bond is two weeks rent.", "I wonder if the bond is two weeks rent."),
            ("Hey can you send the", "Hey can you send the"),
            ("So far  so good.", "So far  so good."),
            ("\"Is the bond two weeks rent.\"", "\"Is the bond two weeks rent.\""),
        ]
        for (input, expected) in questions {
            XCTAssertTrue(CleanupPostPass.markDirectQuestions(input) == expected, input)
        }
        let budget = GuardrailBudget(maxCostRatio: 1, minFreeEdits: 100, minRetention: 0)
        let guardCases = [
            ("Do not send it.", "Do send it.", false),
            ("Never wipe saves.", "Wipe saves.", false),
            ("Can you check my results?", "I can check your results?", false),
            ("We should send our draft.", "You should send your draft.", false),
            ("Position the tier without sounding desperate on the call.",
             "Position the tier on the call.", false),
            ("There are three invoices not a procedure.", "There are three invoices.", false),
            ("Send it unless Priya signs the release.", "Send it.", false),
            ("Please send me the quarterly report today.", "Send the report.", true),
            ("Do not send it.", "Don't send it.", true),
            ("You and I should go.", "I and you should go.", true),
            ("Never send it before Friday.", "Send it never before Friday.", true),
            ("We never ship we never ship.", "We never ship.", true),
            ("Um you know we should send it.", "We should send it.", true),
            ("We need to carefully check it.", "We need to check it carefully.", true),
        ]
        for (input, output, accepted) in guardCases {
            let verdict = CleanupGuardrail.evaluate(input: input, output: output, budget: budget).verdict
            XCTAssertTrue(verdict.isAccepted == accepted, input)
        }
    }

    func testDeterministicCleanupFixes() async {
        let questionCases = [
            ("Can you send it.", "Can you send it?"),
            ("Hey Sam, could you send it.", "Hey Sam, could you send it?"),
            ("Okay, is there room.", "Okay, is there room?"),
            ("Also, what are we doing.", "Also, what are we doing?"),
            ("Sam, what's next.", "Sam, what's next?"),
            ("What’re we doing.", "What’re we doing?"),
            ("How many people.", "How many people?"),
            ("How much is it. How long will it take. How often do we meet.", "How much is it? How long will it take? How often do we meet?"),
            ("It is ready.\nWill they come.", "It is ready.\nWill they come?"),
            ("Can you ask Dr. Jones about 2.5 and src/app.ts.", "Can you ask Dr. Jones about 2.5 and src/app.ts?"),
            ("Can you visit https://example.com or email sam@example.com.", "Can you visit https://example.com or email sam@example.com?"),
            ("I wonder if you can send it.", "I wonder if you can send it."),
            ("I'm not sure if we can go.", "I'm not sure if we can go."),
            ("Let me know if you can come.", "Let me know if you can come."),
            ("Tell me if you need help.", "Tell me if you need help."),
            ("What I'm saying is clear.", "What I'm saying is clear."),
            ("How I did it matters.", "How I did it matters."),
            ("Why we left is clear.", "Why we left is clear."),
            ("When you get a chance, call.", "When you get a chance, call."),
            ("He said \"Can you send it.\" Then left.", "He said \"Can you send it.\" Then left."),
            ("“What is it.”", "“What is it.”"),
            ("'Can you go.'", "'Can you go.'"),
            ("‘Where is it.’", "‘Where is it.’"),
            ("Can you send it? Fine!", "Can you send it? Fine!"),
            ("\"Can you go.\" Can you stay.", "\"Can you go.\" Can you stay?"),
            ("Can you visit https://example.com.", "Can you visit https://example.com?"),
            ("See e.g. what is next.", "See e.g. what is next."),
            ("We use db:migrate.", "We use db:migrate."),
            ("This is ordinary text.", "This is ordinary text."),
        ]
        for (input, expected) in questionCases {
            XCTAssertTrue(CleanupPostPass.markDirectQuestions(input) == expected, input)
        }
        let repeatCases = [
            ("Visit Wagga Wagga today.", "Visit Wagga Wagga today."),
            ("We stayed in Baden Baden.", "We stayed in Baden Baden."),
            ("Dial oh four one two two.", "Dial oh four one two two."),
            ("Use two two.", "Use two two."),
            ("Use 2 2.", "Use 2 2."),
            ("I think Will will send it.", "I think Will will send it."),
            ("Dial oh four one oh four one.", "Dial oh four one oh four one."),
            ("Wagga Wagga is lovely.", "Wagga Wagga is lovely."),
            ("I I think so.", "I think so."),
            ("the the note", "the note"),
        ]
        for (input, expected) in repeatCases {
            XCTAssertTrue(CleanupPostPass.stripSpokenFillers(input) == expected, input)
            XCTAssertTrue(SpokenRepairs.resolve(input) == expected, input)
        }
        XCTAssertTrue(CleanupPostPass.stripSpokenFillers("following up on, on the thing") == "following up on the thing", "comma restart")
        let numberCases = [
            ("twelve dollars fifty", "$12.50"),
            ("twelve dollars and five cents", "$12.05"),
            ("four thousand two hundred dollars and fifty cents", "$4,200.50"),
            ("twelve pounds fifty", "£12.50"),
            ("twelve euros ninety nine", "€12.99"),
            ("twelve dollars zero", "$12.00"),
            ("twelve dollars fifty people", "$12 fifty people"),
            ("twelve dollars fifty minutes", "$12 fifty minutes"),
            ("twelve dollars one hundred cents", "$12 100 cents"),
            ("two pounds of apples", "two pounds of apples"),
            ("eleven fifty nine pm", "11:59pm"),
            ("nine thirty am", "9:30am"),
            ("ten oh five pm", "10:05pm"),
            ("nine thirty", "nine thirty"),
            ("eleven fifty nine", "eleven fifty nine"),
            ("ten sixty pm", "ten sixty pm"),
        ]
        for (input, expected) in numberCases {
            XCTAssertTrue(SpokenNumbers.render(in: input) == expected, input)
        }
        let scratchCases = [
            ("Myfanwy wanted the cushion in forest green scratch that charcoal.", "Myfanwy wanted the cushion in charcoal."),
            ("Myfanwy wanted the cushion in forest green. Scratch that. Charcoal.", "Myfanwy wanted the cushion in charcoal."),
            ("can you activate python three point eleven. Scratch that, python three point twelve?", "can you activate python three point eleven. Scratch that, python three point twelve?"),
            ("Use twelve, scratch that, sixteen chairs.", "Use sixteen chairs."),
            ("Meet at ten am. Scratch that. Eleven am.", "Meet at Eleven am."),
            ("We ship Tuesday, scratch that Wednesday.", "We ship Wednesday."),
            ("Tell Mary Jones. Scratch that. Clara Reed.", "Tell Clara Reed."),
            ("Use the old team room, scratch that, new team room.", "Use the new team room."),
            ("We ship Friday. Scratch that. We ship Monday.", "We ship Monday."),
            ("Keep this. We ship Friday. Delete that.", "Keep this."),
            ("Can you send the file? Scratch that. Leave it.", "Can you send the file? Scratch that. Leave it."),
            ("Can you send the file. Scratch that. Leave it.", "Can you send the file. Scratch that. Leave it."),
            ("Could you send it. Scratch that. Leave it.", "Could you send it. Scratch that. Leave it."),
            ("Would you send it. Scratch that. Leave it.", "Would you send it. Scratch that. Leave it."),
            ("Please send the file. Scratch that. Leave it.", "Please send the file. Scratch that. Leave it."),
            ("Keep this.\nScratch that.\nKeep that.", "Keep this.\nScratch that.\nKeep that."),
            ("Please scratch that label.", "Please scratch that label."),
        ]
        for (input, expected) in scratchCases {
            let output = SpokenRepairs.resolve(input)
            XCTAssertTrue(output == expected, input)
            XCTAssertTrue(SpokenRepairs.resolve(output) == output, "scratch idempotence: \(input)")
        }
        let identifiers = "Run db:migrate rate_limit:user:123 src/App.ts API_KEY docs/Next.md."
        XCTAssertTrue(CleanupPostPass.tidy(identifiers, reference: identifiers, markdownAllowed: false) == identifiers, "reference identifiers")
        XCTAssertTrue(CleanupPostPass.normalisePunctuation("db:migrate;then,go") == "db:migrate; then, go", "colon and comma/semicolon spacing")

        nonisolated final class Echo: CleanupEngine, @unchecked Sendable {
            var isAvailable = true
            var displayName = "Echo"
            func cleanup(_ request: FormattingRequest) async throws -> String { request.input }
        }
        let pipeline = TranscriptCleanupPipeline()
        let echo = Echo()
        pipeline.engineProvider = { _ in echo }
        pipeline.fallbackEngine = { echo }
        let options: [CleanupOption] = [
            .light, .polish, .basic,
            .custom(CustomCleanupRuleset(name: "Verbatim", instructions: "Keep the text verbatim.")),
        ]
        for minimum in [0, 1000] {
            for option in options {
                let plan = CleanupPlan(
                    option: option, includeMarkdown: false, language: "en", autoEditEnabled: false,
                    applyDictionary: false, smartTrailingPunctuation: false,
                    minimumWordCount: minimum, isPreview: true, promptSet: .v3)
                let outcome = await pipeline.clean(raw: "Can you send it.", plan: plan)
                let expected = option.intensity == .lightCleanup || option.intensity == .polish
                    ? "Can you send it?" : "Can you send it."
                XCTAssertTrue(outcome.output == expected, "question level gate: \(option.displayName), minimum \(minimum)")
            }
        }
    }

    func testRoundTwoDeterministicFixes() {
        let questions = [
            ("So hi Maree can you work it out.", "So hi Maree can you work it out?"),
            ("So hi Tahlia, I meant to say, can we go over it.", "So hi Tahlia, I meant to say, can we go over it?"),
            ("I was going to say, can we look at it.", "I was going to say, can we look at it?"),
            ("Okay so can you update the prompt.", "Okay so can you update the prompt?"),
            ("Who else would we ring at this hour.", "Who else would we ring at this hour?"),
            ("Who in their right mind would sign it.", "Who in their right mind would sign it?"),
            ("Can you hold the navy size 14 for Mara", "Can you hold the navy size 14 for Mara?"),
            ("Could you check why it fails to parse the payload", "Could you check why it fails to parse the payload?"),
            ("Who else would we ring at this hour", "Who else would we ring at this hour?"),
            ("Can you send the", "Can you send the"),
            ("Can you tell me if", "Can you tell me if"),
            ("Can you send it...", "Can you send it..."),
            ("Can you send it…", "Can you send it…"),
            ("I wonder who else would ring.", "I wonder who else would ring."),
            ("So hi Maree can you send the", "So hi Maree can you send the"),
            ("\"Can you send it.\"", "\"Can you send it.\""),
            ("Can you send it!", "Can you send it!"),
            ("Ordinary text  stays byte-identical", "Ordinary text  stays byte-identical"),
        ]
        for (input, expected) in questions {
            XCTAssertTrue(CleanupPostPass.markDirectQuestions(input) == expected, input)
        }
        let forms = [
            ("Meet at 2 pm.", "Meet at 2pm.", "Meet at 2pm."),
            ("Meet at 8 am.", "Meet at 8am.", "Meet at 8am."),
            ("Meet at 9:30 pm.", "Meet at 9:30pm.", "Meet at 9:30pm."),
            ("Meet at 12 pm.", "Meet at 12pm.", "Meet at 12pm."),
            ("Meet at 2 am.", "Meet at 2pm.", "Meet at 2 am."),
            ("Meet at 12 pm.", "Meet at 2pm.", "Meet at 12 pm."),
            ("Meet at 2 pm.", "Meet at 2 pm.", "Meet at 2 pm."),
            ("Use 2 pm.", "Use 2pm or 2 pm.", "Use 2 pm."),
            ("Open https://example.org/2 pm.", "Meet at 2pm.", "Open https://example.org/2 pm."),
            ("Email a2 pm@example.org.", "Meet at 2pm.", "Email a2 pm@example.org."),
        ]
        for (input, reference, expected) in forms {
            XCTAssertTrue(CleanupPostPass.restoreDictatedForms(input, reference: reference) == expected, input)
        }
        let repairs = [
            ("We pour tomorrow no sorry Wednesday.", "We pour Wednesday."),
            ("We pour Wednesday no sorry tomorrow.", "We pour tomorrow."),
            ("We pour tomorrow no Wednesday is busy.", "We pour tomorrow no Wednesday is busy."),
            ("We pour tomorrow. No worries Wednesday.", "We pour tomorrow. No worries Wednesday."),
            ("We pour tomorrow? No sorry Wednesday.", "We pour tomorrow? No sorry Wednesday."),
            ("We pour tomorrow!\nNo sorry Wednesday.", "We pour tomorrow!\nNo sorry Wednesday."),
            ("Set expiry to three hundred seconds. No wait, six hundred seconds",
             "Set expiry to six hundred seconds"),
            ("Set expiry to 300 seconds. No wait, 600 seconds.", "Set expiry to 600 seconds."),
            ("It took 300 seconds. No worries, 600 seconds is fine.",
             "It took 300 seconds. No worries, 600 seconds is fine."),
            ("Use the second door.", "Use the second door."),
        ]
        for (input, expected) in repairs {
            let output = SpokenRepairs.resolve(input)
            XCTAssertTrue(output == expected, input)
            XCTAssertTrue(SpokenRepairs.resolve(output) == output, "repair idempotence: \(input)")
        }
        let identifiers = "Run `db:migrate` with `rate_limit:user:123` in `src/App.ts` and `API_KEY`."
        let plain = "Run db:migrate with rate_limit:user:123 in src/App.ts and API_KEY."
        XCTAssertTrue(CleanupPostPass.tidy(identifiers, reference: identifiers, markdownAllowed: false) == plain, "identifier wrappers stripped")
        XCTAssertTrue(CleanupPostPass.tidy(identifiers, reference: identifiers, markdownAllowed: true) == identifiers, "allowed Markdown kept")
        XCTAssertTrue(CleanupPostPass.tidy(plain, reference: plain, markdownAllowed: false) == plain, "plain identifiers unchanged")
        let raw = "Set the Redis key rate_limit:user:123 expiry to three hundred seconds. No wait, six hundred seconds"
        let input = SpokenNumbers.render(in: SpokenRepairs.resolve(raw))
        let output = "Set the Redis key rate_limit:user:123 expiry to 600 seconds."
        XCTAssertTrue(CleanupGuardrail.firstAlteredProtectedToken(input: input, output: output) == nil, "corrected expiry does not protect 300")
        XCTAssertTrue(CleanupGuardrail.firstAlteredProtectedToken(input: input, output: output.replacingOccurrences(of: "600", with: "700")) != nil, "unrelated number changes still vetoed")
    }

    // MARK: - Instruction echo

    func testPastedPromptExampleIsAnEcho() {
        let instructions = CleanupPromptSet.v2.instructionStages(
            for: .polish, includeMarkdown: false, language: "en-AU"
        ).joined(separator: "\n")
        let cutOff = "So the thing that would really help is if we"
        XCTAssertNotNil(
            CleanupGuardrail.echoedInstruction(
                output: cutOff + " remember to peek at the quote.", input: cutOff, instructions: instructions))
    }

    func testWordsTheSpeakerSaidAreNotAnEcho() {
        let instructions = CleanupPromptSet.v2.instructionStages(
            for: .polish, includeMarkdown: false, language: "en-AU"
        ).joined(separator: "\n")
        let said = "remember to peek at the quote before Friday"
        XCTAssertNil(
            CleanupGuardrail.echoedInstruction(
                output: "Remember to peek at the quote before Friday.", input: said, instructions: instructions))
    }

    // MARK: - Preamble strip

    func testDictatedRememberLineIsKept() {
        let take = "Remember: the board pack is due on Friday, so get your sections in."
        XCTAssertEqual(CleanupPostPass.stripModelPreamble(take, reference: take), take)
    }

    func testLeakedSuffixAndWrapperAreStillStripped() {
        XCTAssertEqual(
            CleanupPostPass.stripModelPreamble("We ship Friday.\nREMEMBER: keep every word.", reference: "we ship friday"),
            "We ship Friday.")
        XCTAssertEqual(
            CleanupPostPass.stripModelPreamble("Here is the cleaned text: We ship Friday.", reference: "we ship friday"),
            "We ship Friday.")
    }

    // MARK: - Numbers

    func testDigitsTakeTheirCurrencyAndPercentWords() {
        XCTAssertEqual(
            SpokenNumbers.render(in: "The quote came back at 12,500 dollars, about 20 percent over."),
            "The quote came back at $12,500, about 20% over.")
    }

    func testPoundsOfIsAWeight() {
        XCTAssertEqual(
            SpokenNumbers.render(in: "Grab two pounds of apples and 3 pounds of flour."),
            "Grab two pounds of apples and 3 pounds of flour.")
        XCTAssertEqual(SpokenNumbers.render(in: "It cost twenty pounds."), "It cost £20.")
    }

    func testRepeatedScaleWordsDoNotOverflow() {
        let hundreds = Array(repeating: "hundred", count: 14).joined(separator: " ")
        _ = CleanupGuardrail.tokens("a \(hundreds) times")
        _ = SpokenNumbers.render(in: "a \(hundreds) times")
    }

    // MARK: - Dictated forms

    func testTwentyFourHourTimesAndForeignDigitsAreRestored() {
        XCTAssertEqual(
            CleanupPostPass.restoreDictatedForms("Can you chase that by 15:00? It's version ๔.", reference: "can you chase that by 3pm? It's version four."),
            "Can you chase that by 3pm? It's version 4.")
        XCTAssertEqual(CleanupPostPass.restoreDictatedForms("Meet at 14:00.", reference: "meet at 14:00"), "Meet at 14:00.")
    }

    func testCommaBracketedFillerIsDroppedWhenTheModelLosesTheCommas() {
        let reference = "the build is up so, you know, have a play"
        XCTAssertEqual(
            CleanupPostPass.dropUnbracketedFillers("The build is up so you know have a play.", reference: reference),
            "The build is up so have a play.")
        XCTAssertEqual(
            CleanupPostPass.dropUnbracketedFillers("I'll send it so you know where it is.", reference: "I'll send it so you know where it is"),
            "I'll send it so you know where it is.")
        XCTAssertEqual(
            CleanupPostPass.dropUnbracketedFillers("The build is up so, have a play.", reference: reference),
            "The build is up so have a play.")
    }

    func testClippedMeantToSayIsRestored() {
        XCTAssertEqual(
            CleanupPostPass.restoreClippedScaffolding(
                "Also I meant the second slide still has the old logo.",
                reference: "Also I meant to say, the the second slide still has the old logo."),
            "Also I meant to say, the second slide still has the old logo.")
        XCTAssertEqual(
            CleanupPostPass.restoreClippedScaffolding("I meant the second slide.", reference: "I meant the second slide."),
            "I meant the second slide.")
    }

    func testLoneSmallNumberKeepsTheDictatedWord() {
        XCTAssertEqual(
            CleanupPostPass.restoreDictatedForms("Quick update. 3 things: first.", reference: "quick update. Um, three things. First"),
            "Quick update. three things: first.")
        XCTAssertEqual(
            CleanupPostPass.restoreDictatedForms("It costs $3 each.", reference: "it costs three dollars each"),
            "It costs $3 each.")
        XCTAssertEqual(
            CleanupPostPass.restoreDictatedForms("We need 3 things.", reference: "we need 3 things"),
            "We need 3 things.")
        XCTAssertEqual(
            CleanupPostPass.restoreDictatedForms("Rather than wait 2 to 3 weeks.", reference: "rather than wait two to three weeks"),
            "Rather than wait 2 to 3 weeks.")
    }

    func testAbbreviatedDayAndMonthNamesAreExpanded() {
        let cases = [
            ("Move the retro to Fri at 2pm.", "move the retro to Friday at 2pm", "Move the retro to Friday at 2pm."),
            ("Options by mon.", "options by Monday", "Options by Monday."),
            ("Fri. at 2pm works.", "Friday at 2pm works", "Friday at 2pm works."),
            ("Due 12 Oct.", "due the twelfth of October", "Due 12 October."),
            ("We sat down on Saturday.", "we sat down on Saturday", "We sat down on Saturday."),
            ("Sun's out.", "the sun's out", "Sun's out."),
        ]
        for (output, reference, expected) in cases {
            XCTAssertEqual(CleanupPostPass.restoreDictatedForms(output, reference: reference), expected)
        }
    }

    func testCurrencyIsAProtectedUnit() {
        XCTAssertEqual(CleanupGuardrail.alteredUnit(input: "it was twelve thousand dollars", output: "It was 12,000."), "currency")
        XCTAssertNil(CleanupGuardrail.alteredUnit(input: "it was twelve thousand dollars", output: "It was $12,000."))
        XCTAssertNil(CleanupGuardrail.alteredUnit(input: "it was three dollars fifty cents", output: "It was $3.50."))
    }

    // MARK: - Spoken scaffolding

    func testPolishScaffoldingIsDropped() {
        let cases = [
            ("Um so hi Jack, just following up. Also I meant to say, the second slide still has the old logo.",
             "Hi Jack, just following up. Also, the second slide still has the old logo."),
            ("Okay so can you draft a reply?", "Can you draft a reply?"),
            ("The pack is ready. I was going to say, we should bump the budget.", "The pack is ready. We should bump the budget."),
            ("Okay so the thing is, we need three chairs.", "We need three chairs."),
        ]
        for (input, want) in cases {
            XCTAssertEqual(CleanupPostPass.dropSpokenScaffolding(input), want)
        }
    }

    func testScaffoldingWordsThatCarryMeaningStay() {
        for text in [
            "I meant to say yes but said no on the call.", "The thing is broken again.", "I wanted to say thank you properly.",
            "So far the run has been clean.", "So that's settled.", "Thanks so much for staying.", "Anyway, it's done.",
        ] {
            XCTAssertEqual(CleanupPostPass.dropSpokenScaffolding(text), text)
        }
    }

    // MARK: - Pause flattening

    func testFlatteningKeepsNamesCapitalised() {
        let flat = CleanupPostPass.flattenSentenceBreaks("We should call. Sam about the plan today. And then we wait.")
        XCTAssertTrue(flat.contains("call Sam about"), flat)
        XCTAssertTrue(flat.contains("today and then"), flat)
    }

    // MARK: - Speaker context

    func testSpeakerStageListsVocabularyAndDropsEmptyAbout() {
        let speaker = SpeakerContext(about: "", vocabulary: ["Xero", " Okta ", ""])
        let stages = CleanupPromptSet.v3.instructionStages(
            for: .lightCleanup, includeMarkdown: false, language: "en-AU", speaker: speaker)
        let stage = stages.first { $0.contains("Names and terms they use") }
        XCTAssertNotNil(stage)
        XCTAssertTrue(stage?.contains("Xero, Okta") == true)
        XCTAssertFalse(stage?.contains("About the speaker") == true)
    }

    func testBasicNeverGetsTheSpeakerStage() {
        let speaker = SpeakerContext(about: "Ops lead", vocabulary: ["Xero"])
        let stages = CleanupPromptSet.v3.instructionStages(
            for: .formatting, includeMarkdown: false, language: "en", speaker: speaker)
        XCTAssertFalse(stages.contains { $0.contains("Names and terms") })
    }

    func testSpeakerContextIsCapped() {
        XCTAssertEqual(SpeakerContext(about: String(repeating: "a", count: 900)).about.count, SpeakerContext.maxAboutLength)
        let many = (0..<100).map { "term\($0)" }
        XCTAssertEqual(SpeakerContext(vocabulary: many).vocabulary.count, SpeakerContext.maxVocabularyTerms)
    }

    func testVocabularyTextSplitsOnCommasAndLines() {
        XCTAssertEqual(SpeakerContext(about: "", vocabularyText: "Xero, Okta\nJules,,").vocabulary, ["Xero", "Okta", "Jules"])
    }

    // MARK: - Response cap

    func testResponseTokenLimitLeavesRoomAboveTheInput() {
        let words = Array(repeating: "word", count: 300).joined(separator: " ")
        let light = CleanupRequestBuilder.request(for: words, intensity: .lightCleanup, includeMarkdown: false)
        XCTAssertGreaterThanOrEqual(AppleIntelligenceCleanupEngine.responseTokenLimit(for: light), 300 * 2)
        let short = CleanupRequestBuilder.request(for: "hello there", intensity: .lightCleanup, includeMarkdown: false)
        XCTAssertEqual(AppleIntelligenceCleanupEngine.responseTokenLimit(for: short), 256)
    }

    // MARK: - Deadline

    private final class StalledEngine: CleanupEngine, @unchecked Sendable {
        var isAvailable = true
        var displayName = "Apple Intelligence"
        func cleanup(_ request: FormattingRequest) async throws -> String {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return request.input
        }
    }

    func testStalledModelIsAbandonedAndTheInstantPassShips() async {
        let pipeline = TranscriptCleanupPipeline.scripted(engine: StalledEngine())
        pipeline.deadline = { _ in 0.3 }
        let raw = "um so I think uh we should ship the release on thursday and tell jules"
        let started = Date()

        let outcome = await pipeline.clean(raw: raw, plan: .test(.polish))

        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(outcome.attempts.count, 1, "a stalled model will not answer the next rung either")
        XCTAssertNil(outcome.landed)
        XCTAssertEqual(outcome.output, TranscriptCleanupPipeline.instantPass(raw, plan: .test(.polish)))
    }

    // MARK: - Session pool

    func testLeasedSessionIsNotHandedOutTwice() async {
        let pool = CleanupSessionPool()
        let key = CleanupSessionPool.Key(variant: "x", instructionFingerprint: "i", temperature: 0)
        let first = await pool.lease(key) { "session" }
        let second = await pool.lease(key) { "other" }
        XCTAssertEqual(first, "session")
        XCTAssertNil(second)
        await pool.release(key)
        let third = await pool.lease(key) { "other" }
        XCTAssertEqual(third, "session", "the released session is reused, not rebuilt")
    }
}
