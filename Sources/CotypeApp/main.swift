import Foundation
import Combine
import CotypeCore

// Demo: assemble the loop from pluggable stages and run one completion.
// Each stage is a protocol, so any of these can be swapped without touching
// the pipeline or the others.

let pipeline = CompletionPipeline(
    contextProvider: StaticContextProvider(),
    promptBuilder: TemplatePromptBuilder(),
    engine: MockInferenceEngine(response: "world, and welcome to your own completion engine."),
    renderer: PrintRenderer(),
    inserter: PrintInserter()
)

var cancellables = Set<AnyCancellable>()
pipeline.events.sink { event in
    print("[\(event.phase.rawValue)] \(event.summary)")
}.store(in: &cancellables)

let request = CompletionRequest(
    appIdentifier: "com.example.editor",
    prefix: "func greet() {\n    print(\"hello, ",
    suffix: "\")\n}",
    language: "swift"
)

Task {
    do {
        let result = try await pipeline.complete(request)
        print("\nRESULT: \(result)")
        try await pipeline.accept(result)
        exit(0)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
