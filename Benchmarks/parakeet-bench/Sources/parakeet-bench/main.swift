@preconcurrency import CoreML
import FluidAudio
import Foundation

// Benchmarks Fluid Speech Pro on real recordings with FluidVoice settings (preprocessor on cpuAndGPU).
// Usage: parakeet-bench <model-dir> <audio-dir> <out-dir> <pass,pass,...>
//   pass = ane (default placement, serial chunks) | pN (N parallel chunks, e.g. p4)
//   Alternate passes (e.g. ane,p4,ane,p4) and compare with: ./compare.py results/<run>/pass*.json
//   PARAKEET_BENCH_VOCAB=<FluidVoice-format vocabulary JSON> enables CTC110m vocabulary boosting on every pass.
let args = CommandLine.arguments
let modelDir = URL(fileURLWithPath: args[1])
let audioDir = URL(fileURLWithPath: args[2])
let outDir = URL(fileURLWithPath: args[3])
let passes = args[4].split(separator: ",").map(String.init)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let files = try FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "wav" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
let converter = AudioConverter()
let clips: [(name: String, samples: [Float])] = try files.map {
    ($0.lastPathComponent, try converter.resampleAudioFile($0))
}
let totalAudio = clips.reduce(0.0) { $0 + Double($1.samples.count) / 16_000 }
print("Loaded \(clips.count) clips, \(String(format: "%.1f", totalAudio)) s of audio")

func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

struct ClipResult: Codable {
    let name: String
    let audioSeconds: Double
    let processingSeconds: Double
    let text: String
    let ctcAppliedTerms: [String]?
}

/// Mirrors FluidVoice's ParakeetVocabularyStore: load the JSON, tokenize each term with the CTC110m tokenizer.
func loadBoostingVocabulary(from path: String) async throws -> (CustomVocabularyContext, CtcModels) {
    let loaded = try CustomVocabularyContext.load(from: URL(fileURLWithPath: path))
    let ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
    let tokenizer = try await CtcTokenizer.load(from: CtcModels.defaultCacheDirectory(for: .ctc110m))
    let terms = loaded.terms.compactMap { term -> CustomVocabularyTerm? in
        let tokens = tokenizer.encode(term.text)
        guard !tokens.isEmpty else { return nil }
        return CustomVocabularyTerm(
            text: term.text, weight: term.weight, aliases: term.aliases, tokenIds: nil, ctcTokenIds: tokens)
    }
    let vocabulary = CustomVocabularyContext(
        terms: terms, alpha: loaded.alpha, minCtcScore: loaded.minCtcScore, minSimilarity: loaded.minSimilarity,
        minCombinedConfidence: loaded.minCombinedConfidence, minTermLength: loaded.minTermLength)
    return (vocabulary, ctcModels)
}

var boosting: (CustomVocabularyContext, CtcModels)?
if let path = ProcessInfo.processInfo.environment["PARAKEET_BENCH_VOCAB"] {
    boosting = try await loadBoostingVocabulary(from: path)
    print("Vocabulary boosting with \(boosting?.0.terms.count ?? 0) terms")
}

struct PassResult: Codable {
    let pass: String
    let index: Int
    let loadSeconds: Double
    let clips: [ClipResult]
}

let clock = ContinuousClock()
for (index, pass) in passes.enumerated() {
    let concurrency = pass.hasPrefix("p") ? Int(pass.dropFirst()) ?? 1 : 1
    let loadStart = clock.now
    let models = try await AsrModels.loadLocalOnly(
        from: modelDir, version: .fluidParakeetPro,
        preprocessorComputeUnits: .cpuAndGPU)
    let manager = AsrManager(config: ASRConfig(parallelChunkConcurrency: concurrency))
    try await manager.initialize(models: models)
    if let (vocabulary, ctcModels) = boosting {
        try await manager.configureVocabularyBoosting(vocabulary: vocabulary, ctcModels: ctcModels)
    }
    let loadSeconds = seconds(clock.now - loadStart)
    _ = try await manager.transcribe(clips[0].samples, source: .microphone)

    var results: [ClipResult] = []
    for clip in clips {
        let start = clock.now
        let result = try await manager.transcribe(clip.samples, source: .microphone)
        results.append(
            ClipResult(
                name: clip.name, audioSeconds: Double(clip.samples.count) / 16_000,
                processingSeconds: seconds(clock.now - start), text: result.text,
                ctcAppliedTerms: result.ctcAppliedTerms))
    }
    await manager.cleanup()
    let total = results.reduce(0.0) { $0 + $1.processingSeconds }
    print(
        "pass \(index) \(pass): load \(String(format: "%.2f", loadSeconds)) s, "
            + "transcribe \(String(format: "%.2f", total)) s, RTFx \(String(format: "%.1f", totalAudio / total))")
    let data = try JSONEncoder().encode(PassResult(pass: pass, index: index, loadSeconds: loadSeconds, clips: results))
    try data.write(to: outDir.appendingPathComponent("pass\(index)-\(pass).json"))
}
