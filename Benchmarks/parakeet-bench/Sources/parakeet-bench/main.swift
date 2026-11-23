@preconcurrency import CoreML
import FluidAudio
import Foundation

// Benchmarks Fluid Speech Pro on real recordings with FluidVoice settings (preprocessor on cpuAndGPU).
// Usage: parakeet-bench <model-dir> <audio-dir> <out-dir> <pass,pass,...>
//   pass = ane (default placement, serial chunks) | pN (N parallel chunks, e.g. p4)
//   Alternate passes (e.g. ane,p4,ane,p4) and compare with: ./compare.py results/<run>/pass*.json
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
    let loadSeconds = seconds(clock.now - loadStart)
    _ = try await manager.transcribe(clips[0].samples, source: .microphone)

    var results: [ClipResult] = []
    for clip in clips {
        let start = clock.now
        let result = try await manager.transcribe(clip.samples, source: .microphone)
        results.append(
            ClipResult(
                name: clip.name, audioSeconds: Double(clip.samples.count) / 16_000,
                processingSeconds: seconds(clock.now - start), text: result.text))
    }
    await manager.cleanup()
    let total = results.reduce(0.0) { $0 + $1.processingSeconds }
    print(
        "pass \(index) \(pass): load \(String(format: "%.2f", loadSeconds)) s, "
            + "transcribe \(String(format: "%.2f", total)) s, RTFx \(String(format: "%.1f", totalAudio / total))")
    let data = try JSONEncoder().encode(PassResult(pass: pass, index: index, loadSeconds: loadSeconds, clips: results))
    try data.write(to: outDir.appendingPathComponent("pass\(index)-\(pass).json"))
}
