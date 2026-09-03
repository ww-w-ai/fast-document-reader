//! swift: App/HeadlessExtract.swift
//! the `--extract` CLI, ported far enough to prove the engine
//! reads a real document end to end.
//!
//! This exists to be COMPARED, not shipped: it prints the same bytes the Swift reader prints for
//! the same file, so any difference is a difference in the port rather than in the harness around
//! it. Its output therefore mirrors Swift's exactly, header comment and all — a prettier format
//! here would make every diff unreadable.
//!
//! Scope is deliberately the zip-backed office readers. `.hwp` goes through rhwp's live parse
//! handle and markdown/plain-text go through the encoding detector; neither is on this path yet,
//! so both are refused by name instead of half-answered.

use fastdoc_engine::render::office::{
    docx_reader::DocxReader, office_block::OfficeReadResult,
    office_markdown_serializer::OfficeMarkdownSerializer, odt_reader::OdtReader,
    zip_archive::ZipArchive,
};

fn main() -> std::process::ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let path = match args.get(1) {
        Some(p) => p.clone(),
        None => {
            eprintln!("usage: fastdoc-extract <file.docx|file.odt>");
            return std::process::ExitCode::from(2);
        }
    };

    let extension = std::path::Path::new(&path)
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();

    // swift: HeadlessExtract reads the bytes FIRST and only then builds the archive, and the two
    // failures print differently — "cannot read" for a file that is not there, "cannot extract"
    // for bytes that are there but are not a document. `ZipArchive::from_url` would collapse both
    // into one message, so the two steps stay split here exactly as they are in Swift.
    let data = match swiftshim::Data::contentsOf(&swiftshim::URL::fileURL(&path)) {
        Ok(data) => data,
        Err(e) => {
            eprintln!("cannot read {}: {}", filename(&path), e.message());
            return std::process::ExitCode::FAILURE;
        }
    };
    let archive = match ZipArchive::new(data) {
        Ok(archive) => archive,
        Err(e) => {
            eprintln!("cannot extract {}: {}", filename(&path), e.error_description());
            return std::process::ExitCode::FAILURE;
        }
    };

    // swift: `DocumentTypes.readOffice(_:extension:)` — that dispatcher lives in the host app and is
    // not ported, so the two arms it has for a zip-backed document are spelled out here.
    let result: OfficeReadResult = match extension.as_str() {
        "docx" | "docm" | "dotx" | "dotm" => match DocxReader::read(&archive) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("cannot extract {}: {}", filename(&path), e.error_description());
                return std::process::ExitCode::FAILURE;
            }
        },
        "odt" => match OdtReader::read(&archive) {
            Ok(r) => r,
            Err(e) => {
                // `OdtReadError.error_description` is `Option<String>`, mirroring Swift's
                // `LocalizedError.errorDescription`, which is nil for a case that never carries a
                // message. `localizedDescription` falls back to the type's own name there; the
                // nearest honest thing here is the debug form rather than an empty line.
                let reason = e.error_description().unwrap_or_else(|| format!("{:?}", e));
                eprintln!("cannot extract {}: {}", filename(&path), reason);
                return std::process::ExitCode::FAILURE;
            }
        },
        other => {
            eprintln!("fastdoc-extract does not read .{} yet", other);
            return std::process::ExitCode::from(2);
        }
    };

    let body = OfficeMarkdownSerializer::serialize(&result.blocks, &result.footnotes);
    print!("{}{}\n", header(&filename(&path), &body), body);
    std::process::ExitCode::SUCCESS
}

fn filename(path: &str) -> String {
    std::path::Path::new(path)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.to_string())
}

// swift: App/HeadlessExtract.swift — `header(for:body:)`
fn header(filename: &str, body: &str) -> String {
    let mut note = format!("<!-- Extracted from {} by FastDoc. Best-effort Markdown. -->\n", filename);
    if body.contains(OfficeMarkdownSerializer::RAW_OPEN) {
        note += &format!(
            "<!-- {}…{} marks content whose original structure (e.g. merged-cell tables) could not \
             be safely mapped; treat the text inside as literal. -->\n",
            OfficeMarkdownSerializer::RAW_OPEN,
            OfficeMarkdownSerializer::RAW_CLOSE
        );
    }
    note + "\n"
}
