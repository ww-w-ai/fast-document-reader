import AppKit

/// Foundation's own entry point for an app extension. Xcode's extension templates get here by
/// linking with `-e _NSExtensionMain`; this app has ONE binary serving three shapes (the reader, the
/// two headless flags, and the Quick Look extension), so it calls the symbol itself instead.
///
/// It is a `main`, so it takes `argc`/`argv` — and it really reads them: declared with no
/// parameters it inherits whatever is in those registers and dies in `strlen` on the first argument
/// (`EXC_BAD_ACCESS` inside `EXExtensionMain`, measured before this signature was right).
@_silgen_name("NSExtensionMain")
func NSExtensionMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

// The SAME executable is copied into `Contents/PlugIns/QuickLookPreview.appex`, so the Finder's
// preview runs this reader's own engine with no second render path and no module split (see
// docs/02-planned/quick-look-extension-design.md). Nothing below this line may run in that shape —
// an extension has no Dock icon, no menu bar and no document controller — so it goes FIRST and
// never returns.
if Bundle.main.bundlePath.hasSuffix(".appex") {
    exit(NSExtensionMain(CommandLine.argc, CommandLine.unsafeArgv))
}

// Re-open every folder the user has already granted, before ANY entry point reads a file. The GUI
// wants it live by the time a document's media resolve; the two headless flags below need it to work
// at all, because the sandbox attaches no access to a path handed in on the command line — a granted
// folder is the only way `--extract`/`--pdf` can read anything in the App Store build. One call here
// serves all three entry points (a no-op when the build is not sandboxed).
FolderAccess.restoreGrants()

// Headless text extraction: `FastDocReader --extract <file>` prints Markdown and exits BEFORE any
// GUI setup — no NSApplication, no window, no Dock icon. This must run first so an AI agent can pipe
// a .docx/.odt straight to Markdown without paying to parse the zip/XML itself (see HeadlessExtract).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--extract" {
    exit(HeadlessExtract.run(Array(CommandLine.arguments.dropFirst(2))))
}

// Headless PDF export: `FastDocReader --pdf <file>` prints the SAME pages the reader shows and ⌘P
// prints, then exits — no GUI. Unlike `--extract` this needs AppKit's real layout/font/print stack,
// so `NSApplication.shared` is created (activation PROHIBITED: no Dock icon, no menu bar), but
// `AppDelegate` is never installed (it would present the Open panel — invariant 43) and `app.run()`
// is never called; `HeadlessPDF.run` drives its own window/print synchronously (see HeadlessPDF).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--pdf" {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    exit(HeadlessPDF.run(Array(CommandLine.arguments.dropFirst(2))))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
