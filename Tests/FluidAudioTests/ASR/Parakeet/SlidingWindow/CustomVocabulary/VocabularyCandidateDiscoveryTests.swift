import Foundation
import XCTest

@testable import FluidAudio

/// `hasCTCRescoringCandidates` lets callers skip CTC inference; it must never say false when rescoring could change
/// the transcript. Needs the real CTC110m model and a real 16 kHz recording in `FLUIDAUDIO_PARAKEET_TEST_AUDIO`.
final class VocabularyCandidateDiscoveryTests: XCTestCase {
    private struct Case {
        let transcript: String
        let term: String
        var aliases: [String]? = nil
        var minSimilarity: Float = ContextBiasingConstants.minSimilarityFloor
        let expected: Bool
    }

    private let cases: [Case] = [
        Case(transcript: "quiltor", term: "Quilter", expected: true),
        Case(transcript: "Quilter", term: "Quilter", expected: false),
        Case(transcript: "completely unrelated ordinary speech", term: "Quilter", expected: false),
        Case(transcript: "cloud code", term: "Claude Code", aliases: ["cloud code"], expected: true),
        // Multi-word terms only match multi-word spans, so a single joined word is never a candidate.
        Case(transcript: "cloudcode", term: "Claude Code", aliases: ["cloud code"], expected: false),
        Case(transcript: "Chandra shaker Solanki", term: "Chandra Shekhar Solanki", expected: true),
        Case(transcript: "E S lint", term: "ESLint", aliases: ["E S lint"], expected: true),
        Case(transcript: "the", term: "Azure", minSimilarity: 0.1, expected: false),
        Case(transcript: "AI", term: "AI", expected: false),
        Case(transcript: "quiltor", term: "Quilter", minSimilarity: 0.99, expected: false),
        Case(
            transcript: "fluid boys rock", term: "FluidVoice", aliases: ["fluid voice", "fluid boys"], expected: true),
        Case(transcript: "open X code now", term: "Xcode", aliases: ["X code"], expected: true),
    ]

    func testDiscoveryAgreesWithRescoringOnRealAudio() async throws {
        let directory = CtcModels.defaultCacheDirectory(for: .ctc110m)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path),
            let recording = ProcessInfo.processInfo.environment["FLUIDAUDIO_PARAKEET_TEST_AUDIO"]
        else {
            throw XCTSkip("Install CTC110m and set FLUIDAUDIO_PARAKEET_TEST_AUDIO to real speech")
        }
        let audio = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: recording))
        let models = try await CtcModels.loadDirect(from: directory)
        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        let probabilities = try await spotter.computeLogProbabilities(audioSamples: audio)
        XCTAssertFalse(probabilities.logProbs.isEmpty)
        let tokenizer = try await CtcTokenizer.load(from: directory)
        let duration = Double(audio.count) / Double(ASRConstants.sampleRate)

        for testCase in cases {
            let term = CustomVocabularyTerm(
                text: testCase.term, aliases: testCase.aliases, ctcTokenIds: tokenizer.encode(testCase.term))
            let rescorer = try await VocabularyRescorer.create(
                spotter: spotter, vocabulary: CustomVocabularyContext(terms: [term]), ctcModelDirectory: directory)
            let words = testCase.transcript.split(separator: " ")
            let timings = words.enumerated().map { index, word in
                TokenTiming(
                    token: "▁" + word, tokenId: index + 1,
                    startTime: duration * Double(index) / Double(words.count),
                    endTime: duration * Double(index + 1) / Double(words.count), confidence: 1)
            }
            let discovery = rescorer.hasCTCRescoringCandidates(
                transcript: testCase.transcript, tokenTimings: timings, minSimilarity: testCase.minSimilarity)
            XCTAssertEqual(discovery, testCase.expected, "\(testCase.transcript) -> \(testCase.term)")
            XCTAssertFalse(
                rescorer.hasCTCRescoringCandidates(transcript: testCase.transcript, tokenTimings: []),
                "Empty timings never need CTC")

            guard !discovery else { continue }
            let rescored = rescorer.ctcTokenRescore(
                transcript: testCase.transcript, tokenTimings: timings, logProbs: probabilities.logProbs,
                frameDuration: probabilities.frameDuration, minSimilarity: testCase.minSimilarity)
            XCTAssertFalse(rescored.wasModified, "Skipped CTC must not hide a replacement: \(testCase.transcript)")
            XCTAssertTrue(rescored.replacements.isEmpty)
        }

        let empty = try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: CustomVocabularyContext(terms: []), ctcModelDirectory: directory)
        let timings = [TokenTiming(token: "▁quiltor", tokenId: 1, startTime: 0, endTime: 1, confidence: 1)]
        XCTAssertFalse(empty.hasCTCRescoringCandidates(transcript: "quiltor", tokenTimings: timings))
    }
}
