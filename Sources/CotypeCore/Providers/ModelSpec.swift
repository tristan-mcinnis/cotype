import Foundation

/// The pinned, built-in model that Cotype ships and manages. This is the single
/// source of truth for the model a fresh user acquires in-app: repo, pinned
/// revision, source vs. managed filename (the repo names the file with a `.`
/// after the size tag, but Cotype installs it under a normalized name), the
/// expected SHA-256, the exact byte size, plus the license and the resource
/// figures shown to the user before they commit a multi-GB download.
///
/// Only models listed here can be installed from Setup, so the values in this
/// catalog double as the release's pinned model lockfile.
public struct ModelSpec: Equatable, Sendable {

    /// Human-friendly display name shown in Setup.
    public var modelName: String
    /// Hugging Face repo id.
    public var repo: String
    /// Exact Git commit to pin to.
    public var revision: String
    /// File name as it exists inside the HF repo.
    public var sourceFilename: String
    /// Normalized file name Cotype manages on disk.
    public var managedFilename: String
    /// Expected SHA-256 of the fully downloaded file (verified after download).
    public var expectedSHA256: String
    /// Exact byte size of the file. Used both to show download size and to fail
    /// safely if the server returns the wrong number of bytes.
    public var expectedSize: Int64
    /// License text shown before download.
    public var license: String
    /// Human-facing source page URL (the HF repo page), shown before download.
    public var sourcePageURL: String
    /// Estimated resident memory the loaded model needs, shown before download.
    public var ramUseBytes: Int64
    /// Free disk space required for the download plus headroom, shown before
    /// download and enforced before starting.
    public var diskRequirementBytes: Int64
    /// Optional override for where managed models are installed. `nil` uses the
    /// real `~/Library/Application Support/Cotype/Models`. Tests set this to a
    /// temporary directory so they never touch the user's installed model.
    public var installDirectory: URL?

    public init(
        modelName: String,
        repo: String,
        revision: String,
        sourceFilename: String,
        managedFilename: String,
        expectedSHA256: String,
        expectedSize: Int64,
        license: String,
        sourcePageURL: String,
        ramUseBytes: Int64,
        diskRequirementBytes: Int64,
        installDirectory: URL? = nil
    ) {
        self.modelName = modelName
        self.repo = repo
        self.revision = revision
        self.sourceFilename = sourceFilename
        self.managedFilename = managedFilename
        self.expectedSHA256 = expectedSHA256
        self.expectedSize = expectedSize
        self.license = license
        self.sourcePageURL = sourcePageURL
        self.ramUseBytes = ramUseBytes
        self.diskRequirementBytes = diskRequirementBytes
        self.installDirectory = installDirectory
    }

    /// The directory where Cotype keeps its managed model files.
    public var managedModelsDirectory: URL {
        if let installDirectory { return installDirectory }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cotype", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// The on-disk destination for the managed file.
    public var destinationURL: URL {
        managedModelsDirectory.appendingPathComponent(managedFilename)
    }

    /// The downloader descriptor for this spec, pointing at the source file and
    /// the managed destination, pinned to `revision`.
    public func descriptor() -> ModelDescriptor {
        ModelDescriptor(
            repo: repo,
            filename: sourceFilename,
            destination: destinationURL,
            revision: revision
        )
    }

    /// The built-in model: Gemma 4 2B (E2B) **instruction-tuned** Q4_K_M, pinned
    /// to a commit, with the managed file normalized to
    /// `gemma-4-E2B-it-Q4_K_M.gguf`.
    ///
    /// The earlier pin pointed at `mradermacher/gemma-4-E2B-i1-GGUF` (the *base*
    /// model), which scored 34.5% valid on the seeded completion gate. The
    /// instruction-tuned artifact below (unsloth Q4_K_M, SHA-256 ..e4ec34b8)
    /// loads on the pinned llama.cpp b10665 and scores 58.6% valid on the same
    /// unchanged 29-case gate — a material, evidence-backed improvement.
    public static let gemma4E2BIt = ModelSpec(
        modelName: "Gemma 4 2B (E2B) — Instruction-Tuned Q4_K_M",
        repo: "unsloth/gemma-4-E2B-it-GGUF",
        revision: "0314792d7f1f7e229411f620751375812bb9faf2",
        sourceFilename: "gemma-4-E2B-it-Q4_K_M.gguf",
        managedFilename: "gemma-4-E2B-it-Q4_K_M.gguf",
        expectedSHA256: "740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8",
        expectedSize: 3_106_738_272,
        license: "Apache-2.0",
        sourcePageURL: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF",
        ramUseBytes: 4_800_000_000,
        diskRequirementBytes: 6_500_000_000
    )
}
