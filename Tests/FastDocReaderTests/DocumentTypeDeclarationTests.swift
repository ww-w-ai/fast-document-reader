import XCTest
@testable import FastDocReader

/// `DocumentTypes` and `Resources/Info.plist` describe the same thing to two different audiences —
/// the app's own open panel and macOS — and nothing links them, so they drift silently and the
/// symptom is invisible from inside the app: a `.dev.vars` the panel opens happily cannot be handed
/// to the app by the Finder at all, because with NO declaration anywhere macOS types the file as a
/// throwaway `dyn.…` and refuses to bind any handler to it (`duti -s` → error -50). That is exactly
/// what shipped: the code opened `.conf`/`.cfg`/`.ini`/`.env` while Info.plist named no extension
/// for them, and the markdown declaration was missing `.mkd`/`.mdtext`.
///
/// This is the check CONVENTION §3 asks for, made mechanical. It reads the REAL Info.plist rather
/// than a copy, so a change to either side has to face it.
final class DocumentTypeDeclarationTests: XCTestCase {

    /// Extensions the app opens that are typed by a PUBLIC system UTI instead of a declaration of
    /// ours — every one of them is claimed by the `CFBundleDocumentTypes` entry named beside it, so
    /// macOS already knows who we are for that file. Adding an extension here is a claim that some
    /// other party declares it; if nobody does, the file lands in the `dyn.…` hole above.
    private let coveredBySystemType: [String: String] = [
        "txt": "public.plain-text", "text": "public.plain-text",
        "csv": "public.comma-separated-values-text",
        "tsv": "public.tab-separated-values-text",
        "log": "public.log",
        "docx": "org.openxmlformats.wordprocessingml.document",
        "docm": "org.openxmlformats.wordprocessingml.document.macroenabled",
        "dotx": "org.openxmlformats.wordprocessingml.template",
        "dotm": "org.openxmlformats.wordprocessingml.template.macroenabled",
        "odt": "org.oasis-open.opendocument.text",
    ]

    func testEveryExtensionTheAppOpensIsDeclaredOrCoveredByASystemType() throws {
        let declared = try declaredExtensions()
        let opened = DocumentTypes.markdownExtensions
            + DocumentTypes.plainTextExtensions
            + DocumentTypes.officeExtensions
        for ext in opened {
            XCTAssertTrue(declared.contains(ext) || coveredBySystemType[ext] != nil,
                          "`.\(ext)` is in DocumentTypes but nothing in Info.plist declares it and no "
                        + "system type covers it — macOS will type it `dyn.…` and refuse to bind the "
                        + "app to it. Add it to a UTTypeTagSpecification, or record which public type "
                        + "covers it in `coveredBySystemType`.")
        }
    }

    func testEveryExtensionInfoPlistClaimsIsOneTheAppActuallyOpens() throws {
        for ext in try declaredExtensions() {
            XCTAssertTrue(DocumentTypes.opensInApp(ext),
                          "Info.plist tells macOS we handle `.\(ext)`, but DocumentTypes refuses it — "
                        + "the Finder would hand us a file we then decline to open.")
        }
    }

    /// The system types named above must actually be claimed by a document-type entry, or the app is
    /// relying on a public UTI it never told macOS it handles.
    func testTheSystemTypesWeRelyOnAreClaimedByADocumentType() throws {
        let plist = try infoPlist()
        let claimed = Set(((plist["CFBundleDocumentTypes"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["LSItemContentTypes"] as? [String]) ?? [] })
        for (ext, type) in coveredBySystemType {
            XCTAssertTrue(claimed.contains(type),
                          "`.\(ext)` leans on `\(type)`, which no CFBundleDocumentTypes entry claims.")
        }
    }

    /// Our own exported type has to be claimed too — declaring a type only says it EXISTS; the
    /// document-type entry is what says we open it.
    func testOurOwnConfigTypeIsBothDeclaredAndClaimed() throws {
        let plist = try infoPlist()
        let identifier = "ai.ww-w.fast-md-reader.config-text"
        let exported = (plist["UTExportedTypeDeclarations"] as? [[String: Any]]) ?? []
        XCTAssertTrue(exported.contains { $0["UTTypeIdentifier"] as? String == identifier },
                      "the configuration-file type must be EXPORTED (it is ours, in our namespace)")
        let claimed = Set(((plist["CFBundleDocumentTypes"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["LSItemContentTypes"] as? [String]) ?? [] })
        XCTAssertTrue(claimed.contains(identifier),
                      "declared but unclaimed: macOS would know the type exists and not that we open it")
    }

    // MARK: - Reading the real Info.plist

    private func infoPlist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else {
            throw NSError(domain: "InfoPlist", code: 1)
        }
        return plist
    }

    /// Every filename extension named by a type declaration of ours, imported or exported.
    private func declaredExtensions() throws -> Set<String> {
        let plist = try infoPlist()
        let declarations = ((plist["UTImportedTypeDeclarations"] as? [[String: Any]]) ?? [])
            + ((plist["UTExportedTypeDeclarations"] as? [[String: Any]]) ?? [])
        return Set(declarations.flatMap { decl -> [String] in
            let tags = decl["UTTypeTagSpecification"] as? [String: Any]
            return (tags?["public.filename-extension"] as? [String]) ?? []
        })
    }
}
