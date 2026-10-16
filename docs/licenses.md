# Cotype Licensing and Third-Party Notices

Cotype ships third-party components and consumes a third-party model. This page
summarizes the licensing posture and points to the notices bundled with the app
under `Cotype.app/Contents/Resources/`.

## Cotype itself

- **Status: all rights reserved.** No public license is granted by this
  repository for this personal-ready pass. You may not copy, redistribute, or
  use the Cotype source or binaries except as permitted by the copyright
  holder. This is intentionally left to the maintainer; no MIT (or other)
  license has been granted.
- Third-party components inside Cotype carry their own licenses (below); those
  licenses apply only to those components, not to Cotype as a whole.

## Bundled binaries (third-party)

- **llama.cpp** (`llama` XCFramework, build `b10665`) — **MIT**. Full text in
  [`docs/licenses/LLAMA-CPP-LICENSE`](licenses/LLAMA-CPP-LICENSE).
- Upstream: https://github.com/ggml-org/llama.cpp
- **Sparkle 2** (`Sparkle.framework`, **2.9.6**, SPM pin
  `ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a`) — MIT (plus its embedded
  dependencies; its LICENSE file includes an "EXTERNAL LICENSES" section). Full
  text in [`docs/licenses/SPARKLE-LICENSE.txt`](licenses/SPARKLE-LICENSE.txt).
- Upstream: https://github.com/sparkle-project/Sparkle

## Runtime model (third-party, not bundled)

- **Gemma 4** (`gemma-4-E2B-it-Q4_K_M.gguf`) — released under the **Apache-2.0**
  license, independently of Cotype (which grants no license to the model). See
  [`docs/licenses/GEMMA-MODEL-NOTICE`](licenses/GEMMA-MODEL-NOTICE) and
  <https://ai.google.dev/gemma/docs/gemma_4_license>.
- The model pin: SHA-256 `740185b2...e4ec34b8`, ~3.1 GB (Q4_K_M, instruction-tuned).

## Privacy

- See [`PRIVACY.md`](../PRIVACY.md) for the what-reads / what-stores /
  what-sends notice, bundled into the app as `Cotype-Privacy.md`.

## Personal vs. distribution builds

The scripts embed these notices into the app bundle. They do **not** claim
Developer ID signing or notarization for personal builds; see
[`docs/RELEASE.md`](RELEASE.md) for the documented opt-in release path.
