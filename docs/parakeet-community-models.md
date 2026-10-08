# Parakeet Redux and Ultra

The Models tab offers both models in the Parakeet family. These are offline
Core ML conversions of [Moondream Redux](https://huggingface.co/moondream/parakeet-redux)
and [Moondream Ultra](https://huggingface.co/moondream/parakeet-ultra), not the original
training checkpoints.

| Model | Core ML repository | Approximate download | Minimum runtime OS |
| --- | --- | --- | --- |
| Redux | `FluidInference/parakeet-redux-coreml` | 220 MB | macOS 15 |
| Ultra | `FluidInference/parakeet-ultra-coreml` | 630 MB | macOS 14.2 (Muesli minimum) |

Both support the same 25 languages as Parakeet v3. FluidInference's published
benchmarks describe Redux as a size tradeoff: English accuracy and Neural Engine
speed are lower than v3, while average multilingual accuracy improves. Ultra
improves accuracy at roughly v3 speed with a larger download. These are upstream
measurements, not measurements taken in Muesli.

Redux's first Neural Engine load can take several minutes while Core ML compiles
its 2-bit weights. Later loads reuse Core ML's compilation cache. Keep the app
open during preparation; a small download does not imply a quick first load or
a guaranteed reduction in peak runtime memory.

## Integration

Muesli keeps FluidAudio pinned to 0.15.5. That version lacks Redux/Ultra model
enums, but its public `AsrModels` initializer supports their v3-compatible TDT
contract. The managed downloader installs each conversion into its own directory
and validates all components. `ParakeetCommunityModelLoader` loads those exact
local Core ML files and vocabulary, then uses the v3 decoder architecture.

Do not use `AsrModels.load(from:version: .v3)` for community weights: FluidAudio
0.15.5 resolves its own v3 repository directory and can load the original model
instead. Model identity must also remain distinct for switching, cancellation,
download detection, and deletion. Deleting Redux must not unload or delete Ultra
or v3. Redux's OS requirement is checked before download and again at runtime.

These choices are available for dictation and saved meeting transcription. The
existing live-caption backend remains a separate model. Language selection uses
the same script filter as v3. Existing defaults and the curated onboarding list
remain unchanged.

## Verify on a Mac

Use the build-host requirements in [CONTRIBUTING.md](../CONTRIBUTING.md): Apple
Silicon, macOS 26, Xcode 26.6 / Swift 6.3, and `xcodegen`. After checking out the
feature branch, from the repository root:

```bash
brew install xcodegen cmake
./scripts/build_localvqe.sh
MUESLI_SKIP_SIGN=1 ./scripts/dev-test.sh --lane A
swift test --package-path native/MuesliNative \
  --scratch-path "$HOME/Library/Caches/muesli-spm/parakeet-community-tests" \
  --filter BackendOptionTests --filter FluidAudioTranscriberTests
```

In MuesliDevA, open Models and select Redux, download it, wait for preparation,
then use it for a short dictation. Repeat with Ultra using the same spoken text.
Switch back to v3 and confirm it still works. Delete Redux while Ultra is selected
and confirm Ultra remains downloaded and usable. Check a saved meeting recording
with each model. On macOS 14, Redux must be disabled with an OS requirement while
Ultra remains selectable. Native compilation and these functional checks require
a Mac; Linux CI checks cannot validate inference or the Swift tests.

## Sources

- [FluidInference Redux conversion and benchmarks](https://github.com/FluidInference/FluidAudio/blob/184c111/Documentation/ASR/ParakeetRedux.md)
- [FluidInference Ultra conversion and benchmarks](https://github.com/FluidInference/FluidAudio/blob/184c111/Documentation/ASR/ParakeetUltra.md)
- [FluidAudio 0.15.5 model loading API](https://github.com/FluidInference/FluidAudio/blob/v0.15.5/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift)
