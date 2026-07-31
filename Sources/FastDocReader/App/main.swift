import AppKit

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
