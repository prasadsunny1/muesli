import Foundation
import MuesliCore

/// Uses source symlinks so this harness cannot drift from the app backend.
@main struct ParakeetCommunitySmoke {
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw NSError(domain: "ParakeetCommunitySmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func checkLocalContracts() throws {
        let tokens = (0..<8192).map { "token-\($0)" }
        let array = try JSONSerialization.data(withJSONObject: tokens)
        let dictionary = try JSONSerialization.data(withJSONObject:
            Dictionary(uniqueKeysWithValues: tokens.enumerated().map { (String($0.offset), $0.element) }))
        let parsedArray = try ParakeetCommunityModelLoader.parseVocabulary(array)
        let parsedDictionary = try ParakeetCommunityModelLoader.parseVocabulary(dictionary)
        try require(parsedArray == parsedDictionary, "Vocabulary formats disagree")
        let incomplete = try JSONSerialization.data(withJSONObject: Array(tokens.dropLast()))
        do {
            _ = try ParakeetCommunityModelLoader.parseVocabulary(incomplete)
        } catch {
            try checkCacheIsolation()
            return
        }
        throw NSError(domain: "ParakeetCommunitySmoke", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Incomplete vocabulary was accepted"])
    }

    static func checkCacheIsolation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("parakeet-check-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        var rejectedMissingWeights = false
        do {
            _ = try ParakeetCommunityModelLoader.load(from: root)
        } catch {
            rejectedMissingWeights = true
        }
        try require(rejectedMissingWeights, "Missing community weights fell back to another model")
        let plans = ParakeetTDTModel.allCases.map { $0.plan(modelsRoot: root) }
        try require(Set(plans.map(\.cacheDirectory)).count == plans.count, "Caches overlap")
        for loaded in ParakeetTDTModel.allCases {
            for deleting in ParakeetTDTModel.allCases {
                try require(FluidAudioUnloadPolicy.shouldUnload(loadedModel: loaded, deletingModel: deleting)
                            == (loaded == deleting), "Deletion unloads a sibling model")
            }
        }
        for plan in plans {
            for group in plan.requiredArtifactAlternatives {
                let file = plan.cacheDirectory.appendingPathComponent(group[0])
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([1]).write(to: file)
            }
            try require(plan.isAvailableLocally(), "Complete fixture cache is unavailable")
        }
        try ParakeetTDTModel.redux.plan(modelsRoot: root).delete()
        for model in [ParakeetTDTModel.ultra, .v3, .v2] {
            try require(model.plan(modelsRoot: root).isAvailableLocally(), "Deleting Redux removed \(model)")
        }
        print("PASS: vocabulary completeness, independent caches, deletion and unload isolation")
    }

    static func main() async {
        do {
            try checkLocalContracts()
            guard CommandLine.arguments.count == 2 else {
                throw NSError(domain: "ParakeetCommunitySmoke", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Expected a WAV path or --check"])
            }
            if CommandLine.arguments[1] == "--check" { return }
            let wav = URL(fileURLWithPath: CommandLine.arguments[1])
            let transcriber = FluidAudioTranscriber()
            var failures = 0
            for model in [ParakeetTDTModel.redux, .ultra, .v3] {
                do {
                    print("Loading \(model.rawValue)")
                    try await transcriber.loadModels(model: model)
                    // Deleting a different variant must preserve this loaded runtime.
                    await transcriber.shutdown(ifLoadedModel: model == .redux ? .ultra : .redux)
                    for attempt in 1...2 {
                        let result = try await transcriber.transcribe(wavURL: wav, language: "en")
                        try require(!result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                    "Empty transcript from \(model.rawValue)")
                        print("\(model.rawValue) #\(attempt): \(result.text)")
                    }
                } catch {
                    failures += 1
                    fputs("FAIL \(model.rawValue): \(error.localizedDescription)\n", stderr)
                }
                // The next load exercises switching within the same backend actor.
            }
            await transcriber.shutdown()
            if failures > 0 { exit(1) }
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
