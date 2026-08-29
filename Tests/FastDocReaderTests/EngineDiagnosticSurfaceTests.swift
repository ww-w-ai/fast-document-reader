import XCTest
@testable import FastDocReader

/// What a person — or an agent piping `--extract` — sees when the engine cannot read a document.
///
/// The reader used to write the engine's raw diagnostic straight to stderr the instant a read
/// returned nil, so a corrupt `.docx` answered with two lines: a JSON object
/// (`fastdoc: {"kind":"invalidArchive",…}`) and then a sentence that had thrown the detail away
/// ("The document engine could not read this DOCX file."). The same file through `--pdf`, whose
/// host-side zip open fails first, answered with ONE line naming the actual structure that was
/// missing — so one build disagreed with itself, and the more specific answer was the one that
/// never reached the engine.
///
/// Two rules come out of that and this file gates both: the reader RECORDS rather than prints, and
/// the engine keeps the archive reader's own words instead of `map_err(|_| …)`-ing them away.
final class EngineDiagnosticSurfaceTests: XCTestCase {

    /// Bytes that are not a ZIP, under a name that says they should be.
    private var corruptDocx: Data { Data("not a document at all".utf8) }

    func testAFailedReadLeavesTheReasonWhereTheCallerCanSayItOnce() throws {
        XCTAssertNil(RustEngine.readOffice(corruptDocx, extension: "docx"),
                     "these bytes are not an office document — if this reads, the fixture is wrong")
        let failure = try XCTUnwrap(RustEngine.lastOfficeReadFailure, """
            the read failed and left nothing behind, so every caller can only invent a sentence — \
            which is exactly what `--extract` used to do while the real reason went to stderr as JSON.
            """)
        XCTAssertEqual(failure.kind, "invalidArchive",
                       "the wire tag is what a caller branches on; got \(failure.kind ?? "nil")")
    }

    /// The half that lives in Rust: `ReadOfficeError::InvalidArchive` carries the archive reader's
    /// own sentence. It used to be built with `map_err(|_| …)`, which threw the sentence away and
    /// left every host with "the office archive is invalid" — true, and useless for fixing a file.
    func testTheEngineKeepsTheArchiveReadersOwnWordsRatherThanAGenericSentence() throws {
        XCTAssertNil(RustEngine.readOffice(corruptDocx, extension: "docx"))
        let failure = try XCTUnwrap(RustEngine.lastOfficeReadFailure)
        let sentence = failure.sentence
        XCTAssertTrue(sentence.contains("ZIP") || sentence.contains("central-directory"), """
            the reason a reader can act on is which structure was missing, and this says only \
            "\(sentence)". The pre-port build answered "Not a ZIP archive: no end-of-central-directory \
            record found." and the engine's own archive reader still produces that text — it is being \
            discarded between there and here.
            """)
    }

    /// A diagnostic is read only on the `nil` it belongs to, so it must not be a JSON blob a caller
    /// is forced to hand to a person. `sentence` is the one line a caller prints.
    func testTheSentenceIsProseRatherThanTheRawEnvelope() throws {
        XCTAssertNil(RustEngine.readOffice(corruptDocx, extension: "docx"))
        let failure = try XCTUnwrap(RustEngine.lastOfficeReadFailure)
        XCTAssertFalse(failure.sentence.hasPrefix("{"),
                       "a caller printing this puts it in front of a person: \(failure.sentence)")
        XCTAssertTrue(failure.raw.hasPrefix("{"),
                      "the raw envelope is still available for a log: \(failure.raw)")
    }
}
