import Foundation
import XCTest
@testable import Sotto

final class RecordingPipelineFinalizationTests: XCTestCase {
    func testFinishAttemptsEveryWriterAndAggregatesAllFailures() async throws {
        let mixed = InjectedAudioWriter(finishError: InjectedWriterError.mixed)
        let system = InjectedAudioWriter(finishError: InjectedWriterError.system)
        let microphone = InjectedAudioWriter(finishError: InjectedWriterError.microphone)
        let factory = InjectedWriterFactory(writers: [system, microphone, mixed])
        let root = URL(fileURLWithPath: "/tmp/SottoRecordingPipelineFinalizationTests")
        let configuration = RecordingPipelineConfiguration(
            mixedFileURL: root.appendingPathComponent("mixed.m4a"),
            systemStemURL: root.appendingPathComponent("system.m4a"),
            microphoneStemURL: root.appendingPathComponent("microphone.m4a")
        )
        let pipeline = try RecordingPipeline(
            configuration: configuration,
            onFailure: { _ in },
            writerFactory: { _, _, _ in
                try factory.next()
            }
        )

        do {
            try await pipeline.finish()
            XCTFail("Expected aggregated finalization error")
        } catch let error as RecordingPipelineFinalizationError {
            XCTAssertEqual(
                error.failures.map(\.target),
                [.mixedWriter, .systemWriter, .microphoneWriter]
            )
        }

        XCTAssertEqual(mixed.finishCallCount, 1)
        XCTAssertEqual(system.finishCallCount, 1)
        XCTAssertEqual(microphone.finishCallCount, 1)
    }

    func testFinishAttemptsLaterWritersAfterSingleFailure() async throws {
        let mixed = InjectedAudioWriter()
        let system = InjectedAudioWriter(finishError: InjectedWriterError.system)
        let microphone = InjectedAudioWriter()
        let factory = InjectedWriterFactory(writers: [system, microphone, mixed])
        let root = URL(fileURLWithPath: "/tmp/SottoRecordingPipelineFinalizationTests")
        let configuration = RecordingPipelineConfiguration(
            mixedFileURL: root.appendingPathComponent("mixed.m4a"),
            systemStemURL: root.appendingPathComponent("system.m4a"),
            microphoneStemURL: root.appendingPathComponent("microphone.m4a")
        )
        let pipeline = try RecordingPipeline(
            configuration: configuration,
            onFailure: { _ in },
            writerFactory: { _, _, _ in
                try factory.next()
            }
        )

        await XCTAssertThrowsErrorAsync {
            try await pipeline.finish()
        }

        XCTAssertEqual(mixed.finishCallCount, 1)
        XCTAssertEqual(system.finishCallCount, 1)
        XCTAssertEqual(microphone.finishCallCount, 1)
    }

    func testWriterCreationFailureCancelsCreatedStemsBeforeMixedWriterExists() {
        let system = InjectedAudioWriter()
        let microphone = InjectedAudioWriter()
        let factory = InjectedWriterFactory(
            writers: [system, microphone],
            errorAfterWriters: InjectedWriterFactoryError.injected
        )
        let root = URL(fileURLWithPath: "/tmp/SottoRecordingPipelineFinalizationTests")
        let configuration = RecordingPipelineConfiguration(
            mixedFileURL: root.appendingPathComponent("mixed.m4a"),
            systemStemURL: root.appendingPathComponent("system.m4a"),
            microphoneStemURL: root.appendingPathComponent("microphone.m4a")
        )

        XCTAssertThrowsError(
            try RecordingPipeline(
                configuration: configuration,
                onFailure: { _ in },
                writerFactory: { _, _, _ in
                    try factory.next()
                }
            )
        )

        XCTAssertEqual(system.cancelCallCount, 1)
        XCTAssertEqual(microphone.cancelCallCount, 1)
        XCTAssertEqual(factory.requestCount, 3)
    }
}

private enum InjectedWriterError: Error {
    case mixed
    case system
    case microphone
}

private enum InjectedWriterFactoryError: Error {
    case exhausted
    case injected
}

private final class InjectedAudioWriter: RecordingAudioWriter, @unchecked Sendable {
    private let lock = NSLock()
    private let finishError: Error?
    private var storedFinishCallCount = 0
    private var storedCancelCallCount = 0

    init(finishError: Error? = nil) {
        self.finishError = finishError
    }

    var finishCallCount: Int {
        lock.withLock { storedFinishCallCount }
    }

    var cancelCallCount: Int {
        lock.withLock { storedCancelCallCount }
    }

    func append(_ chunk: CapturedAudioChunk) -> Bool {
        true
    }

    func finish() async throws {
        lock.withLock {
            storedFinishCallCount += 1
        }
        if let finishError {
            throw finishError
        }
    }

    func cancel() {
        lock.withLock {
            storedCancelCallCount += 1
        }
    }
}

private final class InjectedWriterFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var writers: [InjectedAudioWriter]
    private let errorAfterWriters: Error?
    private var storedRequestCount = 0

    init(writers: [InjectedAudioWriter], errorAfterWriters: Error? = nil) {
        self.writers = writers
        self.errorAfterWriters = errorAfterWriters
    }

    var requestCount: Int {
        lock.withLock { storedRequestCount }
    }

    func next() throws -> any RecordingAudioWriter {
        try lock.withLock {
            storedRequestCount += 1
            guard !writers.isEmpty else {
                if let errorAfterWriters {
                    throw errorAfterWriters
                }
                throw InjectedWriterFactoryError.exhausted
            }
            return writers.removeFirst()
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
