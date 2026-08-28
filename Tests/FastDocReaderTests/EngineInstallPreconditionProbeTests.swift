import XCTest
@testable import FastDocReader

/// What the APP sees, as opposed to what the suite sees.
///
/// The font world and the text measurer are process-global and installed once. Every parity test
/// in this suite installs them itself, so inside a full run this check cannot fail — whichever
/// class ran first already installed both. **It is therefore a probe, not a gate**, named by
/// `FMD_INSTALL_PRECONDITION_PROBE` and meant to be run ALONE, the same shape
/// `crates/fastdoc-engine/tests/page_band_measure_port_absence.rs` uses on the Rust side for the
/// same reason (that one gets its own process for free; XCTest does not).
///
/// What it caught, measured on 2026-08-27 before `RustOfficeDocumentHandle.init` installed
/// anything: a real `.hwp` opened, and the first band query PANICKED inside the engine
/// (`swiftshim/src/font_provider.rs:133`), which `guard_scalar` reported as a refusal — so the
/// reader answered from its own arithmetic and the engine was never asked anything. HWP was the
/// worst case and the one that matters: `DocumentTypes.swift:121` branches to `HwpReader` before
/// `RustEngine.readOffice`, the only place that installed fonts, and nothing in `Sources/`
/// installed the measurer at all — while HWP is the only format whose footnotes reach
/// `OfficeReadResult.footnotes`. The flag is opt-in (`Package.swift:14`), so no shipped build was
/// affected; the migration was on course to ship it.
///
///     FMD_INSTALL_PRECONDITION_PROBE=Vendor/rhwp-src/saved/111exam_social.hwp \
///       FMD_RUST_ENGINE=1 swift test --filter EngineInstallPreconditionProbeTests
final class EngineInstallPreconditionProbeTests: XCTestCase {
    func testAHandleOpenedWithNothingPreinstalledStillAnswers() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_INSTALL_PRECONDITION_PROBE"] else {
            throw XCTSkip("set FMD_INSTALL_PRECONDITION_PROBE to a real office document, and run this filter ALONE")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let handle = try XCTUnwrap(RustOfficeDocumentHandle(data: data,
                                                           extension: (path as NSString).pathExtension),
                                   "the engine could not open \(path) at all — wrong fixture, not a precondition failure")
        let sides = handle.bandSides(columnWidth: 400, pageContentWidth: 400,
                                     pageMarginTop: 50, pageMarginBottom: 50,
                                     headersOn: true, footersOn: true,
                                     separatesPages: true, deskGap: nil)
        XCTAssertNotNil(sides, """
            the engine refused a query it can answer — \(RustEngineMeasure.lastErrorKind() ?? "no error kind"). \
            Whoever opens the handle owes it the ports its queries need; call order is not a contract.
            """)
    }
}
