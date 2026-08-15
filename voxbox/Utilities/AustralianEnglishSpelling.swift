import Foundation

/// Australian English support for the dictionary/spoken language setting.
///
/// Whisper (and Parakeet) only know plain `"en"` — they have no regional
/// English variants — so "English (Australia)" is implemented as the `"en"`
/// decode hint plus an offline post-processing pass that rewrites common
/// American spellings the models emit (color, organize, center, …) into
/// their Australian forms (colour, organise, centre, …).
///
/// The pass is a whole-word lookup: only words in the curated table are
/// touched, capitalisation is preserved, and everything runs locally with no
/// network access — matching the app's privacy-first design.
enum AustralianEnglishSpelling {
    /// The language code stored in `transcriptionLanguage` for this variant.
    static let languageCode = "en-AU"

    static func isAustralianEnglish(_ code: String) -> Bool {
        code.caseInsensitiveCompare(languageCode) == .orderedSame
    }

    /// The language hint actually sent to the transcription engine. Regional
    /// English variants decode as plain English; every other code passes
    /// through untouched.
    static func engineLanguage(for code: String) -> String {
        isAustralianEnglish(code) ? "en" : code
    }

    /// Rewrite American spellings in `text` to Australian ones. Whole words
    /// only; unknown words are never modified.
    static func apply(to text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = ""
        result.reserveCapacity(text.count)

        var currentWord = ""
        for character in text {
            if character.isLetter {
                currentWord.append(character)
            } else {
                result += replaced(word: currentWord)
                currentWord = ""
                result.append(character)
            }
        }
        result += replaced(word: currentWord)
        return result
    }

    private static func replaced(word: String) -> String {
        guard !word.isEmpty else { return word }
        guard let australian = replacements[word.lowercased()] else { return word }
        return matchCase(of: word, to: australian)
    }

    /// Carry the source word's capitalisation over to the replacement:
    /// ALL CAPS stays all caps, Initial Caps stays initial caps.
    private static func matchCase(of source: String, to replacement: String) -> String {
        if source == source.uppercased() && source.count > 1 {
            return replacement.uppercased()
        }
        if let first = source.first, first.isUppercase {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    // MARK: - Replacement table

    /// Lowercased US spelling → lowercased Australian spelling.
    /// Built once, lazily, from verb stems plus explicit word families.
    static let replacements: [String: String] = buildReplacements()

    private static func buildReplacements() -> [String: String] {
        var map: [String: String] = [:]

        // -ize → -ise verbs. Stems end in "iz"; appending the shared verb
        // suffixes yields organise/organises/organised/organising/organiser
        // and the matching -isation nouns.
        let izeStems = [
            "apologiz", "authoriz", "capitaliz", "categoriz", "characteriz",
            "civiliz", "coloniz", "criticiz", "customiz", "digitiz",
            "dramatiz", "emphasiz", "energiz", "equaliz", "familiariz",
            "fertiliz", "finaliz", "formaliz", "generaliz", "harmoniz",
            "hospitaliz", "hypnotiz", "idealiz", "immuniz",
            "itemiz", "jeopardiz", "legaliz", "localiz", "magnetiz",
            "materializ", "maximiz", "mechaniz", "memoriz", "minimiz",
            "mobiliz", "moderniz", "monetiz", "monopoliz", "neutraliz",
            "normaliz", "optimiz", "organiz", "patroniz", "penaliz",
            "personaliz", "philosophiz", "populariz", "pressuriz", "prioritiz",
            "privatiz", "publiciz", "rationaliz", "realiz", "recogniz",
            "revolutioniz", "sanitiz", "scrutiniz", "sensationaliz", "serializ",
            "socializ", "specializ", "stabiliz", "standardiz", "steriliz",
            "stigmatiz", "subsidiz", "summariz", "symboliz", "sympathiz",
            "synchroniz", "synthesiz", "terroriz", "theoriz", "utiliz",
            "vandaliz", "vaporiz", "victimiz", "visualiz", "vocaliz",
        ]
        for stem in izeStems {
            // "organiz" + "ation" → "organis" + "ation"
            let auStem = String(stem.dropLast()) + "s"
            for suffix in ["e", "es", "ed", "ing", "er", "ers", "ation", "ations", "able"] {
                map[stem + suffix] = auStem + suffix
            }
        }

        // -yze → -yse verbs.
        for stem in ["analy", "cataly", "paraly", "breathaly"] {
            for suffix in ["ze", "zes", "zed", "zing", "zer", "zers"] {
                let auSuffix = suffix.replacingOccurrences(of: "z", with: "s")
                map[stem + suffix] = stem + auSuffix
            }
        }

        // -or → -our families. Each entry lists the safe inflections; forms
        // where Australian English drops the "u" (colorous-style -ous words,
        // laboratory, honorary) are simply not listed, so they stay unchanged.
        let ourFamilies: [(us: String, au: String, suffixes: [String])] = [
            ("color", "colour", ["", "s", "ed", "ing", "ings", "ful", "less", "fully"]),
            ("favor", "favour", ["", "s", "ed", "ing", "ite", "ites", "able", "ably"]),
            ("flavor", "flavour", ["", "s", "ed", "ing", "ings", "ful", "less", "some"]),
            ("honor", "honour", ["", "s", "ed", "ing", "able", "ably"]),
            ("labor", "labour", ["", "s", "ed", "ing", "er", "ers"]),
            ("neighbor", "neighbour", ["", "s", "ing", "hood", "hoods", "ly"]),
            ("behavior", "behaviour", ["", "s", "al"]),
            ("harbor", "harbour", ["", "s", "ed", "ing"]),
            ("humor", "humour", ["", "s", "ed", "ing", "less"]),
            ("rumor", "rumour", ["", "s", "ed"]),
            ("odor", "odour", ["", "s", "less"]),
            ("vigor", "vigour", [""]),
            ("valor", "valour", [""]),
            ("armor", "armour", ["", "ed", "er", "y"]),
            ("endeavor", "endeavour", ["", "s", "ed", "ing"]),
            ("savor", "savour", ["", "s", "ed", "ing", "y"]),
            ("splendor", "splendour", ["", "s"]),
            ("tumor", "tumour", ["", "s"]),
            ("vapor", "vapour", ["", "s"]),
            ("candor", "candour", [""]),
            ("clamor", "clamour", ["", "s", "ed", "ing"]),
            ("demeanor", "demeanour", ["", "s"]),
            ("fervor", "fervour", [""]),
            ("rancor", "rancour", [""]),
            ("rigor", "rigour", ["", "s"]),
            ("saber", "sabre", ["", "s"]),
            ("parlor", "parlour", ["", "s"]),
        ]
        for family in ourFamilies {
            for suffix in family.suffixes {
                map[family.us + suffix] = family.au + suffix
            }
        }

        // -er → -re and doubled-consonant families, plus assorted common
        // words where the Australian form differs. Explicit full words only.
        let explicit: [String: String] = [
            // -er → -re
            "center": "centre", "centers": "centres",
            "centered": "centred", "centering": "centring",
            "theater": "theatre", "theaters": "theatres",
            "liter": "litre", "liters": "litres",
            "milliliter": "millilitre", "milliliters": "millilitres",
            "kilometer": "kilometre", "kilometers": "kilometres",
            "centimeter": "centimetre", "centimeters": "centimetres",
            "millimeter": "millimetre", "millimeters": "millimetres",
            "fiber": "fibre", "fibers": "fibres",
            "caliber": "calibre", "calibers": "calibres",
            "somber": "sombre",
            "luster": "lustre",
            "meager": "meagre",
            "maneuver": "manoeuvre", "maneuvers": "manoeuvres",
            "maneuvered": "manoeuvred", "maneuvering": "manoeuvring",

            // single ↔ double consonant
            "traveling": "travelling", "traveled": "travelled",
            "traveler": "traveller", "travelers": "travellers",
            "canceling": "cancelling", "canceled": "cancelled",
            "cancelation": "cancellation", "cancelations": "cancellations",
            "labeling": "labelling", "labeled": "labelled",
            "modeling": "modelling", "modeled": "modelled",
            "signaling": "signalling", "signaled": "signalled",
            "fueling": "fuelling", "fueled": "fuelled",
            "marveling": "marvelling", "marveled": "marvelled",
            "marvelous": "marvellous",
            "counselor": "counsellor", "counselors": "counsellors",
            "counseling": "counselling", "counseled": "counselled",
            "jewelry": "jewellery",
            "woolen": "woollen",

            // double → single (US doubles where AU doesn't)
            "enroll": "enrol", "enrolls": "enrols",
            "enrollment": "enrolment", "enrollments": "enrolments",
            "fulfill": "fulfil", "fulfills": "fulfils",
            "fulfillment": "fulfilment",
            "installment": "instalment", "installments": "instalments",
            "skillful": "skilful", "skillfully": "skilfully",

            // -ense → -ence
            "defense": "defence", "defenses": "defences",
            "offense": "offence", "offenses": "offences",
            "pretense": "pretence", "pretenses": "pretences",

            // -og → -ogue
            "catalog": "catalogue", "catalogs": "catalogues",
            "cataloged": "catalogued", "cataloging": "cataloguing",
            "dialog": "dialogue", "dialogs": "dialogues",
            "analog": "analogue", "analogs": "analogues",

            // miscellaneous
            "gray": "grey", "grays": "greys", "grayed": "greyed",
            "airplane": "aeroplane", "airplanes": "aeroplanes",
            "aluminum": "aluminium",
            "mold": "mould", "molds": "moulds", "moldy": "mouldy",
            "smolder": "smoulder", "smoldering": "smouldering",
            "plow": "plough", "plows": "ploughs", "plowed": "ploughed",
            "pajamas": "pyjamas",
            "mom": "mum", "moms": "mums",
            "pediatric": "paediatric", "pediatrician": "paediatrician",
            "anesthesia": "anaesthesia", "anesthetic": "anaesthetic",
            "esthetic": "aesthetic", "esthetics": "aesthetics",
        ]
        map.merge(explicit) { _, new in new }

        return map
    }
}
