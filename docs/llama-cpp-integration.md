# llama.cpp Integration for Cotype

How to run llama.cpp **in-process** from Cotype (a Swift Package Manager target on
macOS) with **Metal** acceleration. Researched 2026 (see Sources for primary
links).

## TL;DR

llama.cpp **no longer ships an SPM `Package.swift`** — it was removed in March
2025 (commit `a057897ad4`, PR #11996) and replaced by a per-commit
**prebuilt XCFramework** (`llama-b<build>-xcframework.zip`) plus a
`build-xcframework.sh` script. The officially documented SPM integration is a
`.binaryTarget` that points at that zip, not a source target.

For Cotype, the recommendation is:

> Add a `.binaryTarget` (or a small maintained wrapper) that consumes the
> official `llama-b<build>-xcframework.zip`, then set `n_gpu_layers = -1` after
> loading the model to actually engage Metal. For a friendlier Swift API, use
> the `pgorzelany/swift-llama-cpp` wrapper. If you don't strictly need
> in-process, drive `llama-server` over its OpenAI-compatible HTTP endpoint
> (much simpler and already matches `OpenAICompatibleEngine`).

## Findings

- **No official `Package.swift` / SPM target today.** llama.cpp had a root
  `Package.swift` from 2023-09 to **2025-03**. It was removed in
  [commit `a057897ad4`](https://github.com/ggml-org/llama.cpp/commit/a057897ad4)
  ([PR #11996](https://github.com/ggml-org/llama.cpp/pull/11996)), which deleted
  `Package.swift`, `Sources/llama/module.modulemap`, and `spm-headers/*.h`.
- **Official replacement: prebuilt XCFramework.** The repo ships
  [`build-xcframework.sh`](https://github.com/ggml-org/llama.cpp/blob/master/build-xcframework.sh),
  which CMake-builds llama.cpp for macOS (universal `arm64;x86_64`), iOS,
  visionOS, and tvOS into `build-apple/llama.xcframework`. It builds with
  `GGML_METAL=ON`, `GGML_METAL_EMBED_LIBRARY=ON` (embeds `default.metallib`),
  `GGML_BLAS_DEFAULT=ON` (Accelerate), `GGML_OPENMP=OFF`. Requires CMake 3.28+,
  macOS ≥13.3.
- **CI publishes `llama-b<build>-xcframework.zip` (~84 MB) on every commit** as
  GitHub pre-releases (e.g. `llama-b10665-xcframework.zip`). See
  [releases](https://github.com/ggml-org/llama.cpp/releases) and
  [build-apple.yml](https://github.com/ggml-org/llama.cpp/blob/master/.github/workflows/build-apple.yml).
- **The officially documented SPM integration is a `.binaryTarget`**:
  [`docs/xcframework.md`](https://github.com/ggml-org/llama.cpp/blob/master/docs/xcframework.md)
  gives the exact pattern — a `swift-tools-version: 5.10` package with
  `.binaryTarget(name:url:checksum:)` pointing at the zip.
- **Versioning gotcha:** semver git tags exist but are **not** Swift package
  versions. The Swift-consumable artifacts are per-commit pre-release zips keyed
  by build number (`b10665`). The semver tags (`v0.1.0`–`v0.3.0`) are for the
  release notes, not SPM.
- **Metal is compiled in but not on by default.**
  `llama_model_default_params()` sets `n_gpu_layers = 0` (CPU-only). To get Metal
  you must set `n_gpu_layers = -1` (all layers) or a high positive value after
  loading the model; [`llama.h`](https://github.com/ggml-org/llama.cpp/blob/master/include/llama.h)
  documents "a negative value means all layers".

## Recommended packages (actively maintained)

| Wrapper | Repo | API | Requirements |
|---|---|---|---|
| **mattt/llama.swift** | https://github.com/mattt/llama.swift | Re-exports the raw llama.cpp C++ APIs directly via the official XCFramework; auto-tracks upstream (tag `2.10549.0` ⇒ build `b10549`) | Swift 6.0+, macOS 13+/iOS 16+, Xcode 16 |
| **pgorzelany/swift-llama-cpp** | https://github.com/pgorzelany/swift-llama-cpp | High-level Swift API: `LlamaService`, chat templates, sampler chain, `useGPU: true`, async token streaming | Swift 6.1+, macOS 14+/iOS 17+ |

The task-named candidates mostly **do not exist or are dead**: `ggml-org/llama-swift`
and `ggml-org/llama.swift` are 404s; `srgtuszy/llama-cpp-swift` depends on the
removed `llama` SPM product and is broken; `StanfordBDHG/llama.cpp` is archived;
`ShenghaiWang/SwiftLlama` requires macOS 15+ and has a fragile dual dependency.

## Recommended approach for Cotype

Cotype targets **macOS 14** (`Platforms: [.macOS(.v14)]` in `Package.swift`) with
`swift-tools-version: 5.10`. The project uses a direct `.binaryTarget` against
the official XCFramework, exactly as `docs/xcframework.md` documents. This keeps
the integration small and avoids requiring the newer toolchains used by
high-level third-party wrappers.

### Step-by-step integration plan

1. **Use `swift-tools-version` 5.10** (already configured in `Package.swift`).
2. **Pick a pinned build.** Choose a recent `llama-b<build>-xcframework.zip`
   from the [releases page](https://github.com/ggml-org/llama.cpp/releases). Note
   **its SHA-256 checksum** — it rotates every commit, so record the exact
   build+checksum you pin.
3. **Add the binary target** to `Package.swift`:
   ```swift
   .binaryTarget(
       name: "llama",
       url: "https://github.com/ggml-org/llama.cpp/releases/download/b10665/llama-b10665-xcframework.zip",
       checksum: "<sha256 from the release asset>"
   )
   ```
4. **Depend on it** from `CotypeCore`:
   ```swift
   .target(name: "CotypeCore", dependencies: [.target(name: "llama")])
   ```
5. **Write a wrapper** (in-process `InferenceEngine`). Add `import llama` in
   your Swift source, load the GGUF with `llama_model_load_from_file(...)`, set
   `model_params.n_gpu_layers = -1` (or a high value) to engage Metal, and adapt
   the token stream into the existing
   `InferenceEngine.stream(prompt:) -> AsyncThrowingStream<CompletionEvent, Error>`
   contract. Register it alongside `MockInferenceEngine` /
   `OpenAICompatibleEngine` in `InferenceEngines.swift`.
6. **Wire in `ModelDownload`.** `GGUFDownloader` (in
   `Sources/CotypeCore/Providers/ModelDownload.swift`) already downloads a
   `ModelDescriptor` from Hugging Face with resume support, giving you a
   `ModelDescriptor.destination` to feed straight into
   `llama_model_load_from_file`.

> **Note on editing `Package.swift`:** this doc describes the *recommended*
> change, but `Package.swift` is owned by Cotype's core; coordinate before
> editing it.

### If you'd rather not bump the toolchain or use a binary target

- **Vendor the static library.** Run the official `build-xcframework.sh`
  (CMake 3.28+ and Xcode 15+ required) and commit the resulting
  `llama.xcframework` into your repo (or a Git LFS/private cache). This is the
  most robust/offline option — it uses official scripts — but costs a long first
  build and a large binary in your tree.
- **Drive `llama-server` over HTTP.** Start `llama-server` / LM Studio / Ollama
  and point Cotype's existing `OpenAICompatibleEngine` at it. This is the
  simplest and most decoupled option, avoids all the binding work, and works
  across languages. Choose this unless you specifically need zero-process
  in-process inference.

## Caveats

- **No source-build SPM path exists anymore.** You cannot depend on llama.cpp
  "from source" via SPM; anything that tries to compile the C library as a
  `systemLibrary` target is stale and gone. Use the XCFramework or vendor it.
- **Checksum rotates every commit.** Pin a specific build+checksum; don't use a
  mutable tag. Locks/bots must update the checksum when you bump.
- **Metal is opt-in.** Compiling the XCFramework with Metal on doesn't mean it's
  used. Set `n_gpu_layers` to a negative value (all layers) or a high positive
  number after loading the model, and confirm via llama.cpp logs that the GPU
  backend was selected.
- **Toolchain floor.** The documented `.binaryTarget` pattern needs
  `swift-tools-version: 5.10` / Xcode 15.3+, which Cotype now uses. The maintained
  high-level wrappers need Swift 6.0–6.1 / Xcode 16.
- **In-process = the model's memory lives in your process.** GGUF models are
  large (multi-GB); this raises Cotype's memory footprint and startup latency
  versus a remote `llama-server`. Consider whether a local/remote server is a
  better fit for a typing-completion loop.

## Sources

- llama.cpp `docs/xcframework.md` (official SPM binaryTarget pattern):
  https://github.com/ggml-org/llama.cpp/blob/master/docs/xcframework.md
- llama.cpp `build-xcframework.sh` (build flags, platforms, Metal/Accelerate):
  https://github.com/ggml-org/llama.cpp/blob/master/build-xcframework.sh
- llama.cpp commit `a057897ad4` / PR #11996 (Package.swift removal):
  https://github.com/ggml-org/llama.cpp/commit/a057897ad4
- llama.cpp releases (xcframework assets):
  https://github.com/ggml-org/llama.cpp/releases
- mattt/llama.swift: https://github.com/mattt/llama.swift
- pgorzelany/swift-llama-cpp: https://github.com/pgorzelany/swift-llama-cpp
- llama.cpp `include/llama.h` (n_gpu_layers semantics):
  https://github.com/ggml-org/llama.cpp/blob/master/include/llama.h
