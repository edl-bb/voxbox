import Foundation

/// Built-in dictations for previews: realistic fillers, false starts, a
/// phonetic slip, an email, a spoken number, a URL and a list. Each is well
/// over the model's minimum word count.
nonisolated enum CleanupSampleTranscripts: String, CaseIterable, Identifiable, Sendable {
    case followUp
    case noteToSelf
    case teamUpdate

    var id: String { rawValue }

    static let onboardingDefault: CleanupSampleTranscripts = .followUp

    var title: String {
        switch self {
        case .followUp: return "Follow-up message"
        case .noteToSelf: return "Note to self"
        case .teamUpdate: return "Team update"
        }
    }

    var text: String {
        switch self {
        case .followUp:
            return
                "Um so hi Priya, just following up on, on the thing we talked about yesterday. Can you send the updated deck to sam.reilly@northwindlabs.com by like Thursday, and, um, put the revised total, I think it was twelve thousand five hundred dollars, into the tracker. Also I meant to say, the the second slide still has the old logo so legal should probably see it for there review before it goes out."
        case .noteToSelf:
            return
                "Okay note to self, um, book the car in for a service sometime next week, probably Tuesday, and, uh, remember to peak at the quote from the other garage first because I think they were like two hundred bucks cheaper. Oh and call mum back, she rang twice, and I I still haven't sorted the, the birthday thing."
        case .teamUpdate:
            return
                "Hey team, quick update. Um, three things. First, the staging build is up at https://staging.voxbox.app so, you know, have a play and log anything weird. Second, I'm, I'm gonna move the retro to Friday at 2pm, hopefully that's okay with everyone. And third, basically we need someone to own the release notes, so if you've got capacity, uh, shout."
        }
    }

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
