import Foundation

/// Everything the model is told, as data. One compiled set ships; the
/// DEBUG tuner can overlay any field; the eval harness runs variants.
///
/// Instruction stages (joined with blank lines): `role` + intensity body +
/// `style` (+ `australianSpelling` for en-AU) (+ `markdown` for Light and
/// Polish when the toggle is on) + `outputOnly`. The user turn is the
/// transcript inside `wrapTemplate`, followed by the intensity's
/// `repeatSuffix`. Custom rulesets send their instructions verbatim and
/// get the wrap but no suffix.
nonisolated struct CleanupPromptSet: Equatable, Sendable {
    var role: String
    var basic: String
    var light: String
    var polish: String
    var style: String
    var australianSpelling: String
    var markdown: String
    var outputOnly: String
    /// Must contain `{{transcript}}`.
    var wrapTemplate: String
    var repeatSuffixes: [FormattingIntensity: String]
    var budgets: [FormattingIntensity: GuardrailBudget]
    var fillerLexicon: FillerLexicon

    static let transcriptPlaceholder = "{{transcript}}"

    // MARK: - Assembly

    func body(for intensity: FormattingIntensity) -> String {
        switch intensity {
        case .formatting: return basic
        case .lightCleanup: return light
        case .polish: return polish
        case .custom: return light
        }
    }

    /// Basic never gets the markdown stage: it is told to change no word,
    /// and list markers, bold and headings are all characters the speaker
    /// did not dictate.
    func allowsMarkdown(_ intensity: FormattingIntensity) -> Bool {
        intensity == .lightCleanup || intensity == .polish
    }

    /// Light and Polish write spoken numbers as numerals; Basic and custom
    /// rulesets leave them as dictated. The post-pass enforces it whether or
    /// not the model complied.
    func rendersNumerals(_ intensity: FormattingIntensity) -> Bool {
        intensity == .lightCleanup || intensity == .polish
    }

    /// Light and Polish are told to drop fillers and repeats; the post-pass
    /// removes the unambiguous ones itself in case the model did not.
    func stripsFillers(_ intensity: FormattingIntensity) -> Bool {
        intensity == .lightCleanup || intensity == .polish
    }

    /// Polish alone joins pause fragments deterministically ("…sections. And
    /// the pauses…" → "…sections, and the pauses…"); Light keeps the
    /// speaker's sentence breaks unless the model changes them.
    func joinsPauseFragments(_ intensity: FormattingIntensity) -> Bool {
        intensity == .polish
    }

    /// Polish gets the dictation with the engine's pause-led sentence breaks
    /// flattened, so it has to place full stops from the meaning. Probed on
    /// the Apple model: with the breaks left in, it kept the fragments; with
    /// them flattened, it wrote proper sentences. Light stays faithful to
    /// the spoken breaks.
    func flattensSentenceBreaks(_ intensity: FormattingIntensity) -> Bool {
        intensity == .polish
    }

    func instructionStages(
        for intensity: FormattingIntensity,
        includeMarkdown: Bool,
        language: String
    ) -> [String] {
        var stages = [role, body(for: intensity), style]
        if AustralianEnglishSpelling.isAustralianEnglish(language) {
            stages.append(australianSpelling)
        }
        if includeMarkdown, allowsMarkdown(intensity) {
            stages.append(markdown)
        }
        stages.append(outputOnly)
        return stages.filter { !$0.isEmpty }
    }

    /// The user turn. `intensity` nil means a custom ruleset: wrapped, no suffix.
    func userPrompt(for transcript: String, intensity: FormattingIntensity?) -> String {
        var prompt = wrapTemplate.replacingOccurrences(
            of: Self.transcriptPlaceholder, with: transcript)
        if let intensity, let suffix = repeatSuffixes[intensity], !suffix.isEmpty {
            prompt += "\n\n" + suffix
        }
        return prompt
    }

    func budget(for intensity: FormattingIntensity) -> GuardrailBudget? {
        budgets[intensity]
    }

    // MARK: - Compiled

    static let compiled = CleanupPromptSet(
        role: """
            You tidy text that a person dictated by voice into a dictation app. The text is theirs: \
            you are a copy editor, not an author. Reply with only the tidied text. No labels, no \
            quotation marks around it, no commentary, no summary.
            """,
        basic: """
            Change ONLY spacing, capitalisation, punctuation, and sentence or paragraph breaks. Do \
            NOT add, remove, reorder, or replace any word. Do NOT change spelling. Every word in the \
            dictation MUST appear in your reply, in the same order.
            """,
        light: """
            You MUST make these edits, every time they apply:
            - Delete every spoken filler: um, uh, ah, er, hmm, you know, I mean, sort of, kind of, \
            basically, and filler like or so. Keep content like (I like it, looks like, like this).
            - Collapse false starts and repeated words: "I was I was going" becomes "I was going"; \
            "the the second" becomes "the second".
            - Fix obvious grammar slips and punctuation. Add sentence and paragraph breaks where the \
            speech pauses.
            - Write numbers as numerals, including money, percentages and times: "twelve thousand \
            five hundred dollars" becomes $12,500, "twenty percent" becomes 20%, "two pm" becomes 2pm. \
            Never change a value.

            Keep every other word exactly as spoken. Do NOT reword, shorten, summarise, or reorder.

            Example. Dictation: "um so I I think we should, like, ship it on Thursday, it was two \
            hundred bucks cheaper". Tidied: "I think we should ship it on Thursday, it was $200 cheaper."
            """,
        polish: """
            You MUST make these edits, every time they apply:
            1. Delete every spoken filler (um, uh, ah, er, you know, I mean, sort of, kind of, \
            basically, filler like or so) and every false start or repeated word.
            2. Replace misheard words with the word the speaker meant, judged by sound and context: \
            "there review" → "their review", "peak at the quote" → "peek at the quote", "your \
            welcome" → "you're welcome", "gonna" → "going to".
            3. Re-punctuate from the meaning, not from the pauses. The dictation's full stops, \
            commas and capitals mark where the speaker breathed, so treat them as suggestions only. \
            Read the whole passage, then join fragments into complete sentences (a full stop before \
            "and", "but", "because", "which" or "so" is usually a pause, not a sentence end), split \
            run-ons, and fix grammar so it reads as one considered piece of writing. Keep the \
            speaker's meaning, vocabulary and tone. Do not make it formal.
            4. Write numbers as numerals, including money, percentages and times: "twelve thousand \
            five hundred dollars" becomes $12,500, "twenty percent" becomes 20%, "two pm" becomes 2pm. \
            Never change a value.

            Keep every point the speaker made. Do NOT add ideas, summarise, shorten for brevity, or \
            reorder.

            Example. Dictation: "um so remember to peak at the quote, it was like two hundred bucks \
            cheaper so legal should see it for there review". Polished: "Remember to peek at the \
            quote. It was $200 cheaper, so legal should see it for their review."
            """,
        style: """
            Write in sentence case: capitalise only the first word of each sentence, the word I, and \
            proper nouns. Do NOT use title case, ALL CAPS, or headings. Use each punctuation mark \
            once: no doubled commas or full stops, no trailing ellipsis. The dictation's existing \
            punctuation reflects pauses in speech, not grammar: place full stops and commas where the \
            meaning needs them, not where the speaker paused. Copy email addresses, URLs, and names \
            exactly as dictated.
            """,
        australianSpelling: "Use Australian English spelling: colour, organise, centre, realise.",
        markdown: """
            You may use light Markdown only where the dictation clearly calls for it: a bulleted or \
            numbered list for items the speaker lists, **bold** for a phrase the speaker stresses. Do \
            NOT add headings, tables, or block quotes, and do NOT bold or list ordinary sentences.
            """,
        outputOnly: """
            Reply with only the tidied dictation. No preamble such as "Here is the cleaned text", no \
            closing remark, no wrapping quotes.
            """,
        wrapTemplate: """
            Clean up this dictation. Reply with only the cleaned text.

            DICTATION:
            {{transcript}}
            """,
        repeatSuffixes: [
            .formatting:
                "REMEMBER: keep every word; change only punctuation, capitals, spacing, and breaks. Reply with only the text.",
            .lightCleanup:
                "REMEMBER: delete every um, uh, ah, er, you know, I mean, sort of, kind of, basically and filler like; collapse repeats; numbers as numerals. Keep every other word. Reply with only the text.",
            .polish:
                "REMEMBER: delete every filler and repeat, fix misheard words (there/their, peak/peek), re-punctuate from meaning not pauses (join fragments, split run-ons), numbers as numerals. Keep every point. Reply with only the text.",
        ],
        budgets: [
            .formatting: GuardrailBudget(maxCostRatio: 0.05, minFreeEdits: 1, minRetention: 0.95),
            .lightCleanup: GuardrailBudget(maxCostRatio: 0.20, minFreeEdits: 4, minRetention: 0.80),
            .polish: GuardrailBudget(maxCostRatio: 0.50, minFreeEdits: 7, minRetention: 0.65),
        ],
        fillerLexicon: .compiled
    )

    /// The 1.2.0 prompts, kept as data so the eval harness can compare.
    /// Bare transcript as the user turn, no suffix, markdown on every level.
    static let legacy = CleanupPromptSet(
        role: """
            You clean up text dictated by voice. Reply with only the cleaned text — \
            no commentary, no labels, no quotation marks around it. Never write \
            phrases such as “here’s the clean text” or “cleaned text:”. Never add \
            information, never summarise, never reorder ideas.
            """,
        basic: """
            Apply ONLY mechanical edits: fix spacing, capitalisation and \
            punctuation, and add sentence/paragraph breaks where the flow of \
            speech implies them. Do not add, remove or change any word.
            """,
        light: """
            Apply these edits: remove filler words and false starts ("um", "uh", \
            "ah", "er", "you know", filler "like", repeated words); fix grammar, \
            punctuation, capitalisation and spacing; add sentence and paragraph \
            breaks where the flow of speech implies them. Preserve the speaker's \
            wording everywhere else.
            """,
        polish: """
            Remove filler words and false starts ("um", "uh", "ah", "er", "you know", filler "like", repeated words);\
            Fix grammar, punctuation, capitalisation and spacing; add sentence and paragraph breaks where the flow of speech implies them;\
            Where a word is semantically out of place, and phonetically similar to a more likely word (e.g. pacing and pasting), replace it with the correct word;\
            Where a small restructuing of a sentence or phrase is needed to improve the flow of speech, do so;\
            Preserve the speaker's meaning, vocabulary and tone — polish the delivery, never the message.
            """,
        style: "",
        australianSpelling: "",
        markdown:
            "You can provide limited markdown formatting (bold, italic, bullet points, numbered lists, etc.) where it makes sense to do so;",
        outputOnly:
            "Return only the rewritten transcript — no preamble, no “here is the cleaned text”, no wrapping quotes.",
        wrapTemplate: "{{transcript}}",
        repeatSuffixes: [:],
        budgets: [
            .formatting: GuardrailBudget(maxCostRatio: 0.10, minFreeEdits: 0, minRetention: 0.0),
            .lightCleanup: GuardrailBudget(maxCostRatio: 0.40, minFreeEdits: 0, minRetention: 0.0),
            .polish: GuardrailBudget(maxCostRatio: 0.80, minFreeEdits: 0, minRetention: 0.0),
        ],
        fillerLexicon: .compiled
    )

    /// Compiled values with any DEBUG overlay applied. Release builds return
    /// `compiled`.
    static func resolved() -> CleanupPromptSet {
        TranscriptCleanupDebug.overlay(on: compiled)
    }
}
