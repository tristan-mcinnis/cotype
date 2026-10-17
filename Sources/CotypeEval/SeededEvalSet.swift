import Foundation

/// A deterministic, hand-picked evaluation set.
///
/// Each case is a realistic code or prose prefix with an expected continuation,
/// one or more equally-valid accepted alternatives, forbidden substrings (so
/// control-token / prompt-echo leakage is measurable), a desired maximum length
/// (so over-generation is measurable), and rubric tags for slicing the
/// scoreboard. The set is stable and versioned: the same cases in the same order
/// every run, so scoreboards are comparable across engines and releases.
///
/// Exact match is intentionally just one of several metrics; these cases are
/// designed to form a meaningful regression baseline, not a single-string lottery.
public enum SeededEvalSet {

    /// Gemma control tokens and channel/tool markers that must never leak.
    public static let gemmaMarkers: [String] = [
        "<|turn>", "<turn|>", "<|channel", "<channel", "<|tool", "<tool",
        "<|think", "<|image", "<|audio", "</text-after-cursor>",
    ]

    /// Build a case's forbidden set from the canonical markers plus the last
    /// non-empty prompt line (a prompt-echo detector) and an optional code fence.
    private static func forbidden(
        _ extra: [String] = [],
        echoOf prefix: String,
        codeFence: Bool
    ) -> [String] {
        var f = gemmaMarkers
        if let lastLine = prefix.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            f.append(String(lastLine))
        }
        if codeFence { f.append("```") }
        f.append(contentsOf: extra)
        return f
    }

    /// The canonical seed set: 29 cases across Swift, Python, TypeScript, Go,
    /// English prose, Markdown, fill-in-the-middle, and abstain/stop.
    public static let cases: [EvalCase] = [
        // MARK: Swift
        EvalCase(
            id: "swift-return-sum",
            prefix: "func add(a: Int, b: Int) -> Int {\n    return ",
            language: "swift",
            expected: "a + b",
            acceptedAlternatives: ["a + b\n}", "a + b\n}"],
            forbiddenSubstrings: forbidden([], echoOf: "func add(a: Int, b: Int) -> Int {\n    return ", codeFence: true),
            maxLength: 32,
            rubricTags: ["code", "swift"]
        ),
        EvalCase(
            id: "swift-guard-throw",
            prefix: "func fetchUser(id: Int) throws -> User {\n    guard id > 0 else {\n        throw ",
            language: "swift",
            expected: "FetchError.invalidID",
            acceptedAlternatives: ["FetchError.invalidID", "UserError.invalidID"],
            forbiddenSubstrings: forbidden(["throw"], echoOf: "func fetchUser(id: Int) throws -> User {\n    guard id > 0 else {\n        throw ", codeFence: true),
            maxLength: 48,
            rubricTags: ["code", "swift"]
        ),
        EvalCase(
            id: "swift-fim-print",
            prefix: "func greet() {\n    print(\"hello, ",
            suffix: "\")\n}",
            language: "swift",
            expected: "world",
            acceptedAlternatives: ["world", "friend"],
            forbiddenSubstrings: forbidden([], echoOf: "func greet() {\n    print(\"hello, ", codeFence: true),
            maxLength: 24,
            rubricTags: ["code", "swift", "fill-middle"]
        ),
        EvalCase(
            id: "swift-struct-property",
            prefix: "struct Person {\n    let name: String\n    var ",
            language: "swift",
            expected: "age: Int",
            acceptedAlternatives: ["age: Int", "age: Int = 0"],
            forbiddenSubstrings: forbidden([], echoOf: "struct Person {\n    let name: String\n    var ", codeFence: true),
            maxLength: 24,
            rubricTags: ["code", "swift"]
        ),
        EvalCase(
            id: "swift-array-map",
            prefix: "let squares = numbers.map { ",
            language: "swift",
            expected: "$0 * $0 }",
            acceptedAlternatives: ["$0 * $0 }", "$0 * $0", "{ $0 * $0 }"],
            forbiddenSubstrings: forbidden([], echoOf: "let squares = numbers.map { ", codeFence: true),
            maxLength: 16,
            rubricTags: ["code", "swift"]
        ),

        // MARK: Python
        EvalCase(
            id: "python-fib",
            prefix: "def fibonacci(n: int) -> int:\n    if n <= 1:\n        return ",
            language: "python",
            expected: "n",
            acceptedAlternatives: ["n", "n\n"],
            forbiddenSubstrings: forbidden([], echoOf: "def fibonacci(n: int) -> int:\n    if n <= 1:\n        return ", codeFence: true),
            maxLength: 12,
            rubricTags: ["code", "python"]
        ),
        EvalCase(
            id: "python-listcomp",
            prefix: "doubled = [x * 2 for x in ",
            language: "python",
            expected: "range(10)]",
            acceptedAlternatives: ["range(10)]", "range(10)]\n"],
            forbiddenSubstrings: forbidden([], echoOf: "doubled = [x * 2 for x in ", codeFence: true),
            maxLength: 16,
            rubricTags: ["code", "python"]
        ),
        EvalCase(
            id: "python-fstring",
            prefix: "print(f\"The result is ",
            language: "python",
            expected: "{total}\")",
            acceptedAlternatives: ["{total}\")", "{total})\""],
            forbiddenSubstrings: forbidden([], echoOf: "print(f\"The result is ", codeFence: true),
            maxLength: 20,
            rubricTags: ["code", "python"]
        ),
        EvalCase(
            id: "python-dict",
            prefix: "config = {\"host\": \"localhost\", \"port\": ",
            language: "python",
            expected: "8080}",
            acceptedAlternatives: ["8080}", "8080 }"],
            forbiddenSubstrings: forbidden([], echoOf: "config = {\"host\": \"localhost\", \"port\": ", codeFence: true),
            maxLength: 16,
            rubricTags: ["code", "python"]
        ),

        // MARK: TypeScript
        EvalCase(
            id: "ts-add",
            prefix: "function add(a: number, b: number): number {\n  return ",
            language: "typescript",
            expected: "a + b",
            acceptedAlternatives: ["a + b", "a + b;"],
            forbiddenSubstrings: forbidden([], echoOf: "function add(a: number, b: number): number {\n  return ", codeFence: true),
            maxLength: 24,
            rubricTags: ["code", "typescript"]
        ),
        EvalCase(
            id: "ts-interface",
            prefix: "interface User {\n  id: number;\n  name: string;\n  email: ",
            language: "typescript",
            expected: "string;",
            acceptedAlternatives: ["string;", "string; }"],
            forbiddenSubstrings: forbidden([], echoOf: "interface User {\n  id: number;\n  name: string;\n  email: ", codeFence: true),
            maxLength: 28,
            rubricTags: ["code", "typescript"]
        ),
        EvalCase(
            id: "ts-async-fetch",
            prefix: "async function fetchUser(id: string) {\n  const res = await fetch(`/users/${id}`);\n  return res.",
            language: "typescript",
            expected: "json();",
            acceptedAlternatives: ["json();", "json()"],
            forbiddenSubstrings: forbidden([], echoOf: "async function fetchUser(id: string) {\n  const res = await fetch(`/users/${id}`);\n  return res.", codeFence: true),
            maxLength: 16,
            rubricTags: ["code", "typescript"]
        ),

        // MARK: Go
        EvalCase(
            id: "go-add",
            prefix: "func add(a, b int) int {\n    return ",
            language: "go",
            expected: "a + b",
            acceptedAlternatives: ["a + b", "a + b\n}"],
            forbiddenSubstrings: forbidden([], echoOf: "func add(a, b int) int {\n    return ", codeFence: true),
            maxLength: 24,
            rubricTags: ["code", "go"]
        ),
        EvalCase(
            id: "go-readfile",
            prefix: "func readFile(name string) ([]byte, error) {\n    data, err := os.ReadFile(name)\n    if err != nil {\n        return nil, ",
            language: "go",
            expected: "err",
            acceptedAlternatives: ["err", "err\n"],
            forbiddenSubstrings: forbidden([], echoOf: "func readFile(name string) ([]byte, error) {\n    data, err := os.ReadFile(name)\n    if err != nil {\n        return nil, ", codeFence: true),
            maxLength: 12,
            rubricTags: ["code", "go"]
        ),
        EvalCase(
            id: "go-println",
            prefix: "fmt.Println(\"Hello, ",
            language: "go",
            expected: "world\")",
            acceptedAlternatives: ["world\")", "world\")\n"],
            forbiddenSubstrings: forbidden([], echoOf: "fmt.Println(\"Hello, ", codeFence: true),
            maxLength: 16,
            rubricTags: ["code", "go"]
        ),

        // MARK: English prose
        EvalCase(
            id: "en-fox",
            prefix: "The quick brown fox jumps over the lazy ",
            expected: "dog",
            acceptedAlternatives: ["dog", "dog."],
            forbiddenSubstrings: forbidden([], echoOf: "The quick brown fox jumps over the lazy ", codeFence: false),
            maxLength: 16,
            rubricTags: ["prose", "en"]
        ),
        EvalCase(
            id: "en-hamlet",
            prefix: "To be or not to be, that is the ",
            expected: "question",
            acceptedAlternatives: ["question", "question."],
            forbiddenSubstrings: forbidden([], echoOf: "To be or not to be, that is the ", codeFence: false),
            maxLength: 16,
            rubricTags: ["prose", "en"]
        ),
        EvalCase(
            id: "en-capital",
            prefix: "The capital of France is ",
            expected: "Paris",
            acceptedAlternatives: ["Paris", "Paris.", "the city of Paris"],
            forbiddenSubstrings: forbidden([], echoOf: "The capital of France is ", codeFence: false),
            maxLength: 24,
            rubricTags: ["prose", "en"]
        ),
        EvalCase(
            id: "en-email-open",
            prefix: "Hi Sarah,\n\nI hope you're doing well. I'm writing to let you know that the ",
            expected: "meeting has been rescheduled",
            acceptedAlternatives: ["meeting has been rescheduled", "meeting is moved", "meeting has moved"],
            forbiddenSubstrings: forbidden([], echoOf: "Hi Sarah,\n\nI hope you're doing well. I'm writing to let you know that the ", codeFence: false),
            maxLength: 48,
            rubricTags: ["prose", "email", "multiline"]
        ),
        EvalCase(
            id: "en-tone-friendly",
            prefix: "Thanks so much for your help. It really means a ",
            expected: "lot",
            acceptedAlternatives: ["lot", "lot to me"],
            forbiddenSubstrings: forbidden([], echoOf: "Thanks so much for your help. It really means a ", codeFence: false),
            maxLength: 16,
            rubricTags: ["prose", "tone"]
        ),
        EvalCase(
            id: "en-list",
            prefix: "- apples\n- bananas\n- ",
            expected: "cherries",
            acceptedAlternatives: ["cherries", "cherries\n"],
            forbiddenSubstrings: forbidden([], echoOf: "- apples\n- bananas\n- ", codeFence: false),
            maxLength: 16,
            rubricTags: ["prose", "list"]
        ),

        // MARK: Markdown
        EvalCase(
            id: "md-heading",
            prefix: "## Getting started\n\nTo begin, install the ",
            language: "markdown",
            expected: "CLI",
            acceptedAlternatives: ["CLI", "command-line tool"],
            forbiddenSubstrings: forbidden([], echoOf: "## Getting started\n\nTo begin, install the ", codeFence: false),
            maxLength: 24,
            rubricTags: ["markdown"]
        ),
        EvalCase(
            id: "md-link",
            prefix: "[Cotype](https://github.com/",
            language: "markdown",
            expected: "example/cotype)",
            acceptedAlternatives: ["example/cotype)", "cotype)"],
            forbiddenSubstrings: forbidden([], echoOf: "[Cotype](https://github.com/", codeFence: false),
            maxLength: 32,
            rubricTags: ["markdown"]
        ),
        EvalCase(
            id: "md-fence-json",
            prefix: "```json\n{\"name\": \"Alice\", \"age\": ",
            language: "json",
            expected: "30}",
            acceptedAlternatives: ["30}", "30}\n"],
            forbiddenSubstrings: forbidden([], echoOf: "```json\n{\"name\": \"Alice\", \"age\": ", codeFence: false),
            maxLength: 16,
            rubricTags: ["markdown", "json"]
        ),

        // MARK: Fill-in-the-middle
        EvalCase(
            id: "fim-swift-close",
            prefix: "func area(width: Int, height: Int) -> Int {\n    return wid",
            suffix: "th * height\n}",
            language: "swift",
            expected: "",
            acceptedAlternatives: [],
            forbiddenSubstrings: forbidden([], echoOf: "func area(width: Int, height: Int) -> Int {\n    return wid", codeFence: true),
            maxLength: 24,
            rubricTags: ["code", "swift", "fill-middle"]
        ),
        EvalCase(
            id: "fim-python-fstring",
            prefix: "total = price * (1 + tax)\nprint(f\"Total: ",
            suffix: "\")\n",
            language: "python",
            expected: "{total}",
            acceptedAlternatives: ["{total}", "{total:.2f}"],
            forbiddenSubstrings: forbidden([], echoOf: "total = price * (1 + tax)\nprint(f\"Total: ", codeFence: true),
            maxLength: 16,
            rubricTags: ["code", "python", "fill-middle"]
        ),

        // MARK: Abstain / stop
        EvalCase(
            id: "abstain-empty",
            prefix: "The end.",
            expected: "",
            acceptedAlternatives: [],
            forbiddenSubstrings: forbidden([], echoOf: "The end.", codeFence: false),
            maxLength: 4,
            rubricTags: ["abstain", "stop"]
        ),
        EvalCase(
            id: "abstain-comment-end",
            prefix: "// TODO: no action needed",
            language: "swift",
            expected: "",
            acceptedAlternatives: [],
            forbiddenSubstrings: forbidden([], echoOf: "// TODO: no action needed", codeFence: true),
            maxLength: 4,
            rubricTags: ["abstain", "code", "swift", "stop"]
        ),
        EvalCase(
            id: "abstain-html-close",
            prefix: "</body>\n</html>",
            language: "html",
            expected: "",
            acceptedAlternatives: [],
            forbiddenSubstrings: forbidden([], echoOf: "</body>\n</html>", codeFence: false),
            maxLength: 4,
            rubricTags: ["abstain", "code", "html", "stop"]
        ),
    ]

    /// Short natural-language cases where the active window supplies the fact or
    /// phrase needed for the next 1-4 words. These test the product loop Cotype
    /// is for, separately from the legacy mixed code/prose suite.
    public static let windowContextCases: [EvalCase] = [
        EvalCase(
            id: "window-meeting-time",
            prefix: "Let's meet on ",
            extra: ["windowContext": "The meeting has moved to Thursday at 3pm."],
            expected: "Thursday at 3pm",
            acceptedAlternatives: ["Thursday at 3pm.", "Thursday"],
            maxLength: 24,
            rubricTags: ["window-context", "prose"]
        ),
        EvalCase(
            id: "window-person-name",
            prefix: "Hi ",
            extra: ["windowContext": "From: Jane Doe\nSubject: Acme project debrief"],
            expected: "Jane",
            acceptedAlternatives: ["Jane,", "Jane Doe,"],
            maxLength: 16,
            rubricTags: ["window-context", "email"]
        ),
        EvalCase(
            id: "window-decision",
            prefix: "We'll proceed with the ",
            extra: ["windowContext": "Decision: use the shorter 12-slide version."],
            expected: "shorter 12-slide version",
            acceptedAlternatives: ["shorter version", "12-slide version"],
            maxLength: 32,
            rubricTags: ["window-context", "decision"]
        ),
        EvalCase(
            id: "window-request-object",
            prefix: "Yes, I'll send the ",
            extra: ["windowContext": "Can you send the revised deck today?"],
            expected: "revised deck today",
            acceptedAlternatives: ["revised deck", "deck today"],
            maxLength: 24,
            rubricTags: ["window-context", "reply"]
        ),
        EvalCase(
            id: "window-order-id",
            prefix: "Regarding order ",
            extra: ["windowContext": "Order number: AX-2048\nStatus: awaiting approval"],
            expected: "AX-2048",
            acceptedAlternatives: ["AX-2048,", "AX-2048:", "number AX-2048"],
            maxLength: 16,
            rubricTags: ["window-context", "entity"]
        ),
        EvalCase(
            id: "window-location",
            prefix: "The session will be held in ",
            extra: ["windowContext": "Venue confirmed: Studio 3, Acme office."],
            expected: "Studio 3",
            acceptedAlternatives: ["Studio 3.", "Studio 3, Acme", "Studio 3, Acme office."],
            maxLength: 32,
            rubricTags: ["window-context", "entity"]
        ),
    ]

    /// Held-out cases with real text after the cursor. Run this set in both
    /// prompt styles (`COTYPE_EVAL_PROMPT_STYLE`) to compare the two supported
    /// behaviors: the instruction lane sends the suffix as delimited
    /// after-cursor context, the continuation lane only filters against it.
    /// These cases are not part of the default gate because the continuation
    /// lane cannot see the suffix and would be scored unfairly there.
    public static let postCursorCases: [EvalCase] = [
        EvalCase(
            id: "postcursor-name",
            prefix: "Please loop in ",
            suffix: "Sam Rivera on the review.",
            expected: "Sam Rivera",
            acceptedAlternatives: ["Sam Rivera", "Sam"],
            forbiddenSubstrings: forbidden(["Sam Rivera on the review"], echoOf: "Please loop in ", codeFence: false),
            maxLength: 24,
            rubricTags: ["postCursor", "entity"]
        ),
        EvalCase(
            id: "postcursor-punctuation",
            prefix: "The total came to ",
            suffix: " (including tax).",
            expected: "120",
            acceptedAlternatives: ["120", "120 USD", "120 dollars"],
            forbiddenSubstrings: forbidden(["including tax"], echoOf: "The total came to ", codeFence: false),
            maxLength: 16,
            rubricTags: ["postCursor", "prose"]
        ),
        EvalCase(
            id: "postcursor-cjk",
            prefix: "我们下周一",
            suffix: "开会讨论一下",
            expected: "开会",
            acceptedAlternatives: ["开会", "开个会"],
            forbiddenSubstrings: forbidden(["开会讨论一下"], echoOf: "我们下周一", codeFence: false),
            maxLength: 12,
            rubricTags: ["postCursor", "cjk"]
        ),
        EvalCase(
            id: "postcursor-partial-word",
            prefix: "return wid",
            suffix: "th * height",
            expected: "",
            acceptedAlternatives: [],
            forbiddenSubstrings: forbidden([], echoOf: "return wid", codeFence: false),
            maxLength: 8,
            rubricTags: ["postCursor", "abstain"]
        ),
        EvalCase(
            id: "postcursor-email",
            prefix: "Reply to ",
            suffix: "sam@example.com for the details.",
            expected: "sam@example.com",
            acceptedAlternatives: ["sam@example.com", "sam"],
            forbiddenSubstrings: forbidden(["for the details"], echoOf: "Reply to ", codeFence: false),
            maxLength: 24,
            rubricTags: ["postCursor", "entity"]
        ),
        EvalCase(
            id: "postcursor-quote",
            prefix: "She said \"",
            suffix: "\" and left the room.",
            expected: "I will be there",
            acceptedAlternatives: ["I will be there", "hello"],
            forbiddenSubstrings: forbidden(["and left the room"], echoOf: "She said \"", codeFence: false),
            maxLength: 24,
            rubricTags: ["postCursor", "prose"]
        ),
        EvalCase(
            id: "postcursor-bracket",
            prefix: "Operating profit (",
            suffix: ") rose 4%.",
            expected: "EBITDA",
            acceptedAlternatives: ["EBITDA", "operating"],
            forbiddenSubstrings: forbidden(["rose 4%"], echoOf: "Operating profit (", codeFence: false),
            maxLength: 16,
            rubricTags: ["postCursor", "entity"]
        ),
        EvalCase(
            id: "postcursor-list",
            prefix: "1. first item\n2. ",
            suffix: "\n3. third item",
            expected: "second item",
            acceptedAlternatives: ["second item", "second"],
            forbiddenSubstrings: forbidden(["third item"], echoOf: "1. first item\n2. ", codeFence: false),
            maxLength: 16,
            rubricTags: ["postCursor", "list"]
        ),
    ]

    /// Held-out personal-writing cases for the instruction lane's style control.
    /// The run's system message carries the style request
    /// (`COTYPE_EVAL_SYSTEM_PROMPT`); a case "passes" when the continuation
    /// violates none of the markers below. The expected text is empty on purpose:
    /// this set measures adherence and contamination, not exact wording.
    public static let adherenceCases: [EvalCase] = [
        EvalCase(
            id: "adherence-note",
            prefix: "Just a quick note to say ",
            expected: "",
            forbiddenSubstrings: adherenceViolations,
            maxLength: 60,
            rubricTags: ["adherence", "writing"]
        ),
        EvalCase(
            id: "adherence-timeline",
            prefix: "Following up on the timeline, ",
            expected: "",
            forbiddenSubstrings: adherenceViolations,
            maxLength: 60,
            rubricTags: ["adherence", "writing"]
        ),
        EvalCase(
            id: "adherence-status",
            prefix: "Here is where things stand: ",
            expected: "",
            forbiddenSubstrings: adherenceViolations,
            maxLength: 60,
            rubricTags: ["adherence", "writing"]
        ),
        EvalCase(
            id: "adherence-client",
            prefix: "The client asked whether ",
            expected: "",
            forbiddenSubstrings: adherenceViolations,
            maxLength: 60,
            rubricTags: ["adherence", "writing"]
        ),
        EvalCase(
            id: "adherence-budget",
            prefix: "On the budget question, ",
            expected: "",
            forbiddenSubstrings: adherenceViolations,
            maxLength: 60,
            rubricTags: ["adherence", "writing"]
        ),
        EvalCase(
            id: "adherence-workshop",
            prefix: "Quick update from the workshop: ",
            expected: "",
            forbiddenSubstrings: adherenceViolations,
            maxLength: 60,
            rubricTags: ["adherence", "writing"]
        ),
        EvalCase(
            id: "adherence-launch",
            prefix: "To keep the launch moving, ",
            expected: "",
            forbiddenSubstrings: adherenceViolations,
            maxLength: 60,
            rubricTags: ["adherence", "writing"]
        ),
        EvalCase(
            id: "adherence-review",
            prefix: "Thanks for the review — ",
            expected: "",
            forbiddenSubstrings: adherenceViolations,
            maxLength: 60,
            rubricTags: ["adherence", "writing"]
        ),
    ]

    /// Markers that violate the style request used for `adherenceCases`
    /// ("Never use exclamation marks. Use 'we' rather than 'I'.") plus the
    /// few-shot contamination markers. `"I "` and `"I'"` catch a standalone
    /// first-person subject without matching letters inside words.
    public static let adherenceViolations: [String] = [
        "!", "I ", "I'", "I’", "I,",
        "Input:", "Output:", "→", "```", "Sure,", "Here is",
    ]
}
