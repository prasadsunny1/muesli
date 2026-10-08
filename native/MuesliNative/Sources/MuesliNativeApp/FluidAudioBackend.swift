import FluidAudio
import CoreML
import Foundation
import MuesliCore

/// Native Swift transcription backend using FluidAudio's Parakeet TDT model
/// running on Apple's Neural Engine (ANE) via CoreML.
actor FluidAudioTranscriber {
    private var asrManager: AsrManager?
    private var loadedModel: ParakeetTDTModel?
    private var loadGeneration: UInt64 = 0

    enum TranscriberError: Error, LocalizedError {
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "FluidAudio models not loaded. Call loadModels() first."
            }
        }
    }

    /// Downloads models (if needed) and initializes the ASR manager.
    /// Keep the weight identity separate from the shared v3 decoder contract.
    func loadModels(
        model: ParakeetTDTModel = .v3,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        if model == .redux {
            guard #available(macOS 15, *) else {
                throw AsrModelsError.loadingFailed("Parakeet Redux requires macOS 15 or later.")
            }
        }
        if loadedModel == model, asrManager != nil { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        asrManager = nil
        loadedModel = model // Also invalidate an in-flight load if this model is deleted.

        fputs("[fluidaudio] downloading/loading models: \(model.rawValue)...\n", stderr)
        let plan = model.plan()
        let manager = try await ManagedASRModelDownloader.loadValidated(
            plan,
            progress: progress,
            progressSnapshot: progressSnapshot
        ) { modelDirectory in
            let preparing = ModelDownloadProgress.preparing(
                modelID: plan.modelID,
                message: "Loading Parakeet into Core ML..."
            )
            progress?(0.95, preparing.message)
            progressSnapshot?(preparing)
            let models: AsrModels
            switch model {
            case .v2, .v3:
                models = try await AsrModels.load(from: modelDirectory, version: model == .v2 ? .v2 : .v3)
            case .redux:
                // FluidAudio 0.15.5 predates these model enums. Its repository
                // loader resolves v3's canonical cache, so loading with .v3
                // there would silently use the original weights. Construct the
                // public model bundle from this exact managed directory instead.
                models = try ParakeetCommunityModelLoader.load(from: modelDirectory)
            }
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        guard generation == loadGeneration else { throw CancellationError() }
        self.asrManager = manager
        self.loadedModel = model
        let preparing = ModelDownloadProgress.preparing(
            modelID: plan.modelID,
            message: "Loading Parakeet into Core ML..."
        )
        progress?(1, nil)
        progressSnapshot?(preparing.replacing(phase: .ready, message: "Model ready"))
        fputs("[fluidaudio] models ready\n", stderr)
    }

    /// Transcribe a WAV file URL directly.
    /// `language` is an optional ISO code enabling FluidAudio's script-level
    /// token filter on the v3 joint decoder (v2 ignores the hint; nil = auto).
    func transcribe(wavURL: URL, language: String? = nil) async throws -> ASRResult {
        guard let asrManager else { throw TranscriberError.notLoaded }
        let languageHint = language.flatMap(Language.init(rawValue:))
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        return try await asrManager.transcribe(wavURL, decoderState: &decoderState, language: languageHint)
    }

    func shutdown() {
        asrManager = nil
        loadedModel = nil
        loadGeneration &+= 1
    }

    func shutdown(ifLoadedModel model: ParakeetTDTModel) {
        guard FluidAudioUnloadPolicy.shouldUnload(
            loadedModel: loadedModel,
            deletingModel: model
        ) else { return }
        shutdown()
    }
}

enum FluidAudioUnloadPolicy {
    static func shouldUnload(
        loadedModel: ParakeetTDTModel?,
        deletingModel: ParakeetTDTModel
    ) -> Bool {
        loadedModel == deletingModel
    }
}

/// Redux uses v3's 8192-token TDT contract, with independent weights.
/// Load locally only: the managed downloader owns transport and completeness.
enum ParakeetCommunityModelLoader {
    static func load(from directory: URL) throws -> AsrModels {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        func component(_ name: String, units: MLComputeUnits) throws -> MLModel {
            let config = MLModelConfiguration()
            config.computeUnits = units
            return try MLModel(contentsOf: directory.appendingPathComponent(name), configuration: config)
        }
        let vocabulary = try parseVocabulary(
            Data(contentsOf: directory.appendingPathComponent("parakeet_vocab.json"))
        )
        return try AsrModels(
            encoder: component("Encoder.mlmodelc", units: .cpuAndNeuralEngine),
            preprocessor: component("Preprocessor.mlmodelc", units: .cpuOnly),
            decoder: component("Decoder.mlmodelc", units: .cpuAndNeuralEngine),
            joint: component("JointDecisionv3.mlmodelc", units: .cpuAndNeuralEngine),
            configuration: configuration,
            vocabulary: vocabulary,
            version: .v3
        )
    }

    static func parseVocabulary(_ data: Data) throws -> [Int: String] {
        let json = try JSONSerialization.jsonObject(with: data)
        let vocabulary: [Int: String]
        if let tokens = json as? [String] {
            vocabulary = Dictionary(uniqueKeysWithValues: tokens.enumerated().map { ($0.offset, $0.element) })
        } else if let tokens = json as? [String: String] {
            var parsed: [Int: String] = [:]
            for (key, token) in tokens {
                guard let id = Int(key), id >= 0, parsed[id] == nil else {
                    throw AsrModelsError.loadingFailed("Invalid Parakeet vocabulary token ID: \(key)")
                }
                parsed[id] = token
            }
            vocabulary = parsed
        } else {
            throw AsrModelsError.loadingFailed("Parakeet vocabulary must be an array or token-ID dictionary.")
        }
        guard (0..<8192).allSatisfy({ vocabulary[$0] != nil }) else {
            throw AsrModelsError.loadingFailed("Parakeet v3-family vocabulary must contain all 8192 tokens.")
        }
        return vocabulary
    }
}
