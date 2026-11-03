import Foundation

/// Everyday writing with a synthetic author: emails, chat, replies and Chinese.
///
/// The forbidden list is the test. The author's details must stay out of text
/// that does not call for them, and the model must not talk as an assistant. All
/// text here is invented.
public enum ProseEvalSet {

    public static let facts = """
    Name: Alex Morgan
    Work email: alex@northbay.example
    Personal email: alex.morgan@mail.example
    Company: Northbay Research, a qualitative research consultancy
    Role: Managing Partner
    Base: Lisbon
    """

    private static let authorDetails = ["Alex", "Morgan", "Northbay", "Lisbon", "Managing Partner", "@mail.example"]
    private static let assistantTalk = [
        "Gemma", "language model", "DeepMind", "capital of France", "the context", "provided text",
        "you're typing", "you are typing", "Type away", "own voice", "正在输入",
    ]

    /// Many continuations are right, so read the forbidden count for these, not
    /// the valid count. The expected text is a marker: an empty one would score
    /// the case as an abstain.
    private static func unrelated(_ prefix: String) -> EvalCase {
        EvalCase(
            id: "plain-\(prefix.prefix(20))",
            prefix: prefix,
            expected: "any",
            forbiddenSubstrings: authorDetails + assistantTalk,
            rubricTags: ["prose", "unrelated"]
        )
    }

    private static func callsForFacts(_ prefix: String, _ expected: String) -> EvalCase {
        EvalCase(
            id: "facts-\(prefix.prefix(20))",
            prefix: prefix,
            expected: expected,
            forbiddenSubstrings: assistantTalk,
            rubricTags: ["prose", "facts"]
        )
    }

    private static func reply(_ onScreen: String, _ prefix: String, _ expected: String) -> EvalCase {
        EvalCase(
            id: "reply-\(prefix.prefix(20))",
            prefix: prefix,
            extra: ["windowContext": onScreen],
            expected: expected,
            forbiddenSubstrings: authorDetails + assistantTalk,
            rubricTags: ["prose", "reply"]
        )
    }

    /// A long, loose chat draft, with a busy window above it.
    private static func draft(_ tail: String) -> EvalCase {
        let earlier = "yeah i looked through it and most of it seems right to me, the numbers line up with what we saw last week. "
        return EvalCase(
            id: "draft-\(tail.suffix(20))",
            prefix: String(repeating: earlier, count: 7) + tail,
            extra: ["windowContext": "New\nSearch\nMore\nProject notes\nThe word limit is 4 and the task is finished. Let me know what you think about the results.\nAuto\n"],
            expected: "any",
            forbiddenSubstrings: authorDetails + assistantTalk,
            rubricTags: ["prose", "draft"]
        )
    }

    private static func midword(_ prefix: String, _ expected: String, tag: String) -> EvalCase {
        EvalCase(
            id: "\(tag)-\(prefix.suffix(18))",
            prefix: prefix,
            expected: expected,
            forbiddenSubstrings: authorDetails + assistantTalk,
            rubricTags: ["midword", tag]
        )
    }

    /// The caret stops partway through a word, or right after a whole one. The
    /// `word` group ends on a real word that is also the start of a likelier
    /// one, which a spell checker cannot tell apart. `whole` guards the opposite
    /// mistake: a finished word must still get its space.
    public static let midwordCases: [EvalCase] = [
        midword("I wanted to ask you a questi", "on", tag: "partial"),
        midword("Let me get back to you tomorr", "ow", tag: "partial"),
        midword("I can't make it becau", "se", tag: "partial"),
        midword("Thanks for the informa", "tion", tag: "partial"),
        midword("We should probab", "ly", tag: "partial"),
        midword("hmm ok that seems fine to me.\n\nlet me kno", "w", tag: "partial"),
        midword("Sorry for the late respon", "se", tag: "partial"),
        midword("Could you send me the docum", "ent", tag: "partial"),
        midword("we nee", "d", tag: "partial"),
        midword("I would really appreci", "ate", tag: "partial"),
        midword("Hope you had a good weeke", "nd", tag: "partial"),
        midword("Can we schedu", "le", tag: "partial"),

        midword("hmm ok that seems fine to me.\n\nso i thin", "k", tag: "word"),
        midword("I don't wan", "t", tag: "word"),
        midword("Let's have a meet", "ing", tag: "word"),
        midword("Are you goin", "g", tag: "word"),
        midword("I wil", "l", tag: "word"),
        midword("Thanks for your hel", "p", tag: "word"),
        midword("Can you tel", "l", tag: "word"),
        midword("We have to wor", "k", tag: "word"),
        midword("I really like tha", "t", tag: "word"),
        midword("What are you doin", "g", tag: "word"),

        midword("I went to the", " ", tag: "whole"),
        midword("lets not go to", " ", tag: "whole"),
        midword("Thanks for sending the report", " ", tag: "whole"),
        midword("Let me know if you", " ", tag: "whole"),
        midword("I think we should", " ", tag: "whole"),
        midword("Can you send me the", " ", tag: "whole"),
        midword("We talked about it in", " ", tag: "whole"),
        midword("She said that she", " ", tag: "whole"),
        midword("Please check the numbers and", " ", tag: "whole"),
    ]

    /// Invented past writing by an invented fieldwork researcher.
    public static let authorWriting = [
        "ok i'll check the transcripts tonight and flag anything weird",
        "can you send me the screener before the kickoff",
        "the moderator guide still needs a pass, i'll do it after lunch",
        "hey mei, the chengdu interviews are confirmed for tuesday",
        "i think the fieldwork is on track but recruitment is a bit slow",
        "sorry for the late reply, was stuck in the debrief",
        "let me look at the deck and get back to you tomorrow morning",
        "we should push the shanghai groups by a week if recruitment slips",
        "can you share the quote bank when it's ready",
        "i'll ping the client once the discussion guide is signed off",
        "let's do a quick call before the debrief so we're aligned",
        "i need the translated transcripts by friday at the latest",
        "looks fine to me, send the costing over when you can",
        "not sure about the third theme, feels thin, can we dig into the quotes",
        "the client asked for a topline by monday so let's prioritize that",
        "please check the recruiter's numbers against the screener",
    ]

    private static func learned(_ prefix: String, _ fits: String, tag: String) -> EvalCase {
        EvalCase(
            id: "\(tag)-\(prefix.suffix(20))",
            prefix: prefix,
            expected: fits,
            forbiddenSubstrings: assistantTalk,
            rubricTags: ["learned", tag]
        )
    }

    /// Read with and without `--no-writing`. `expected` lists words that fit this
    /// author, split by "|". `said` retraces a phrase from `authorWriting`, `new`
    /// does not, and `other` is about something else, so the author's world must
    /// stay out of it.
    public static let learnedCases: [EvalCase] = [
        learned("can you send me the", "screener|transcripts|deck|quote|costing|guide|topline", tag: "said"),
        learned("i'll check the", "transcripts|screener|deck|numbers|quotes", tag: "said"),
        learned("the client asked for", "topline|deck|quote|costing", tag: "said"),
        learned("we should push the", "groups|fieldwork|kickoff|interviews|debrief|shanghai", tag: "said"),
        learned("let's do a quick", "call", tag: "said"),
        learned("i need the", "transcripts|screener|deck|quote|topline|translated", tag: "said"),
        learned("please check the", "recruiter|numbers|screener|transcripts|quotes", tag: "said"),
        learned("not sure about the", "third|theme|quote|sample|screener", tag: "said"),

        learned("could you forward the", "screener|transcripts|deck|quote|costing|guide|topline|debrief", tag: "new"),
        learned("i'll review the", "transcripts|screener|deck|quotes|guide|topline|costing", tag: "new"),
        learned("did you see the", "transcripts|screener|deck|quotes|guide|topline|costing|debrief", tag: "new"),
        learned("before the kickoff we", "screener|guide|recruit|moderator|deck", tag: "new"),
        learned("the recruitment in", "chengdu|shanghai|city|guangzhou|beijing", tag: "new"),
        learned("i'm still waiting on the", "transcripts|screener|deck|quote|costing|recruiter|client", tag: "new"),

        learned("The dishwasher", "kitchen", tag: "other"),
        learned("happy birthday! hope", "birthday|day", tag: "other"),
        learned("my flight to", "flight", tag: "other"),
        learned("the kids are", "kids", tag: "other"),
        learned("the restaurant was", "food|good", tag: "other"),
        learned("my dad said", "dad", tag: "other"),
    ]

    public static let cases: [EvalCase] = [
        unrelated("thanks for"), unrelated("The meeting"), unrelated("The meeting went"),
        unrelated("I think we should"), unrelated("Can you send me"), unrelated("hey, are you"),
        unrelated("We need to"), unrelated("Quick question"), unrelated("Quick question about the"),
        unrelated("Looking forward"), unrelated("Sounds good"), unrelated("Sorry for the late"),
        unrelated("Let me know"), unrelated("I'm not sure"), unrelated("Please find"),
        unrelated("As discussed"), unrelated("fix the bug in"), unrelated("refactor this so that"),
        unrelated("write a short summary of"), unrelated("why does the test"), unrelated("我觉得"),
        unrelated("今天下午"), unrelated("麻烦你"), unrelated("Here's what I"),
        unrelated("I wanted to follow up on our call yesterday. The client liked the first draft but asked for"),
        unrelated("Thanks for sending the transcript so quickly. I read through it last night and I think the main"),
        unrelated("Hi Mei, hope you had a good weekend. Could you please send me the"),
        unrelated("Let me check with the team and get back to you by"),
        unrelated("上周我们在成都访谈了十二位消费者，大部分人都表示"),
        unrelated("这个方案我看过了，整体没问题，但是预算部分还需要"),

        callsForFacts("My email is ", "alex@northbay.example"),
        callsForFacts("My name is ", "Alex Morgan"),
        callsForFacts("I work at ", "Northbay Research"),
        callsForFacts("I'm based in ", "Lisbon"),

        draft("hmm ok so the speed is pretty slow. i need a quick"),
        draft("hmm ok so the speed is pretty slow. i just felt like the learning curve in"),
        draft("hmm ok so the speed is pretty slow.\n\nlets not go to"),
        draft("hmm ok so the speed is pretty slow.\n\nfor example it says"),
        draft("hmm ok so the speed is pretty slow.\n\nso i thin"),
        draft("hmm ok so the speed is pretty slow.\n\nthats super not related to"),
        draft("hmm ok so the speed is pretty slow.\n\nplease push it and then"),
        draft("hmm ok so the speed is pretty slow.\n\nwhat do you think about "),

        reply("Anna: can we move the Thursday call to 3pm?", "Sure, ", "that works for me"),
        reply("Ben: did you get the budget numbers for Q3?", "Yes, ", "I got them"),
        reply("Subject: Invoice 4471 overdue\nPlease pay invoice 4471 by Friday.", "Hi, I will pay invoice", " 4471 by Friday"),
        reply("Fay: is the Tokyo fieldwork still on for May?", "Yes, the Tokyo", " fieldwork is still on"),
    ]
}
