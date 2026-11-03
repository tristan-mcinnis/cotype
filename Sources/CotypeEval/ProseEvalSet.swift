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
