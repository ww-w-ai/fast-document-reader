import Foundation

/// S1B's Swift-side materialization of the project-authored S1A fixture recipes in
/// `Scripts/rust-baseline.py` recipe version 1. The ZIP writer is copied from the proven
/// `OfficeDocumentTests.buildZip` reference and intentionally supports stored entries only.
enum S1BOfficeFixtures {
    private static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
         UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)]
    }

    private static func zip(_ entries: [(String, Data)]) -> Data {
        struct Entry { let name: [UInt8]; let data: Data; let offset: Int }
        var body: [UInt8] = []
        var prepared: [Entry] = []
        for (name, data) in entries {
            let bytes = Array(name.utf8)
            let offset = body.count
            body += le32(0x0403_4b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
            body += le32(0) + le32(UInt32(data.count)) + le32(UInt32(data.count))
            body += le16(UInt16(bytes.count)) + le16(0) + bytes + Array(data)
            prepared.append(Entry(name: bytes, data: data, offset: offset))
        }
        var central: [UInt8] = []
        for entry in prepared {
            central += le32(0x0201_4b50) + le16(20) + le16(20) + le16(0) + le16(0)
            central += le16(0) + le16(0) + le32(0) + le32(UInt32(entry.data.count))
            central += le32(UInt32(entry.data.count)) + le16(UInt16(entry.name.count))
            central += le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
            central += le32(UInt32(entry.offset)) + entry.name
        }
        let offset = body.count
        var result = body + central
        result += le32(0x0605_4b50) + le16(0) + le16(0)
        result += le16(UInt16(entries.count)) + le16(UInt16(entries.count))
        result += le32(UInt32(central.count)) + le32(UInt32(offset)) + le16(0)
        return Data(result)
    }

    static let docx = zip([
        ("word/document.xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>FastDoc baseline</w:t></w:r></w:p></w:body></w:document>
        """.utf8)),
    ])

    static let odt = zip([
        ("mimetype", Data("application/vnd.oasis.opendocument.text".utf8)),
        ("content.xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:text><text:p>FastDoc baseline</text:p></office:text></office:body></office:document-content>
        """.utf8)),
    ])
}
