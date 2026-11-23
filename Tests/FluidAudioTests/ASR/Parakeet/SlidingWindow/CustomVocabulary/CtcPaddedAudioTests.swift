import CoreML
import Foundation
import XCTest

@testable import FluidAudio

/// The CTC mel model reads its whole fixed window, so the padding after a short clip must be zero.
/// Needs the real CTC110m model and a real recording in `FLUIDAUDIO_PARAKEET_TEST_AUDIO`.
final class CtcPaddedAudioTests: XCTestCase {
    func testShortClipIsCopiedAndPaddingIsZero() async throws {
        let directory = CtcModels.defaultCacheDirectory(for: .ctc110m)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path),
            let recording = ProcessInfo.processInfo.environment["FLUIDAUDIO_PARAKEET_TEST_AUDIO"]
        else {
            throw XCTSkip("Install CTC110m and set FLUIDAUDIO_PARAKEET_TEST_AUDIO to real speech")
        }
        let audio = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: recording))
        let models = try await CtcModels.loadDirect(from: directory)
        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        let clip = Array(audio.prefix(ASRConstants.sampleRate))

        for _ in 0..<8 {
            let (array, count) = try spotter.prepareAudioArray(clip)
            XCTAssertEqual(count, clip.count)
            XCTAssertGreaterThan(array.count, count, "A one-second clip must leave padding")
            let values = (0..<array.count).map { array[$0].floatValue }
            for (index, sample) in clip.enumerated() {
                XCTAssertEqual(values[index], sample, accuracy: array.dataType == .float16 ? 1e-3 : 0)
            }
            XCTAssertTrue(values[count...].allSatisfy { $0 == 0 }, "Padding after the clip must be zero")
        }
    }
}
