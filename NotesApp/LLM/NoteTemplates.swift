import Foundation

/// Starting points for the notes prompt (Settings ▸ Notes prompt). Each sets the structure; the
/// shared tail adds the date handling, the Hindi note for Hinglish meetings and the glossary.
/// Every template keeps an "## Action items" checklist, which the checked action-item step fills.
enum NoteTemplate: String, CaseIterable, Identifiable {
    case general, standup, oneOnOne, interview, client

    var id: String { rawValue }

    var name: String {
        switch self {
        case .general: return "General meeting"
        case .standup: return "Stand-up"
        case .oneOnOne: return "One-on-one"
        case .interview: return "Interview"
        case .client: return "Client or sales call"
        }
    }

    var prompt: String { AppSettings.defaultPrompt(structure: structure) }

    private var structure: String {
        switch self {
        case .general:
            return AppSettings.generalStructure
        case .standup:
            return """
            Write stand-up notes from the transcript above.

            Structure (omit a section if there is nothing for it):
            ## Summary
            One or two sentences on where the team stands.
            ## Updates
            One "### Name" heading per person, with what they did, what they are doing next and anything \
            blocking them. Keep ticket numbers, systems and dates exactly as said.
            ## Blockers
            Each blocker, who raised it and who can unblock it.
            ## Action items
            - [ ] what — who — when (only if said) [12:56]
            """
        case .oneOnOne:
            return """
            Write notes from this one-on-one meeting, from the transcript above.

            Structure (omit a section if there is nothing for it):
            ## Summary
            Two sentences: what was discussed and how it was left.
            ## Topics
            Each topic as a "### Topic" heading with what each person said, including feedback given in \
            either direction, concerns and goals.
            ## Agreements
            What both people agreed to, one line each, with the transcript time like [12:56].
            ## Action items
            - [ ] what — who — when (only if said) [12:56]
            """
        case .interview:
            return """
            Write interview notes from the transcript above.

            Structure (omit a section if there is nothing for it):
            ## Summary
            Two or three sentences: the role, the candidate's background and the overall signal, without \
            judging more than the conversation supports.
            ## Background
            Experience and projects the candidate described, with specifics (companies, systems, numbers).
            ## Strengths
            Each with the answer that shows it and its transcript time like [12:56].
            ## Concerns
            Each with the answer that raised it and its transcript time.
            ## Notable answers
            Short quotes where the wording matters.
            ## Action items
            - [ ] what — who — when (only if said) [12:56]
            """
        case .client:
            return """
            Write notes from this client or sales call, from the transcript above.

            Structure (omit a section if there is nothing for it):
            ## Summary
            Two or three sentences: who the client is, what they want and where things stand.
            ## Client needs and concerns
            What they asked for, problems they described, objections, with specifics.
            ## What we committed to
            One line each with the transcript time like [12:56].
            ## What they committed to
            One line each with the transcript time.
            ## Pricing, scope and timeline
            Every number, date and scope point said.
            ## Action items
            - [ ] what — who — when (only if said) [12:56]
            """
        }
    }
}
