#!/usr/bin/env python3
"""Regenerate `docs/fixtures/office/giant-table.odt`.

`GiantTableDeferralTests` needs a document whose table is over the deferral line
(`rows >= 50 AND rows x columns >= 500`, see `OfficeTextBuilder.giantTableIndices`), and no such
document can be committed: `docs/` is gitignored, and none of the real ones are ours to publish.
So the fixture is GENERATED, and the test skips with a pointer here when it is absent.

The shape is deliberately minimal — a heading, a paragraph, one 60x10 table, a paragraph — so the
test can assert on exact block ids and on text that appears only inside the grid ("r59c9").

    python3 Scripts/make-giant-table-fixture.py
"""

import os
import zipfile

ROWS, COLS = 60, 10
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "docs", "fixtures", "office", "giant-table.odt")

NS = ('xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
      'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" '
      'xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" '
      'xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" '
      'xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"')

rows = "".join(
    "<table:table-row>"
    + "".join(f'<table:table-cell office:value-type="string">'
              f"<text:p>r{r}c{c}</text:p></table:table-cell>" for c in range(COLS))
    + "</table:table-row>"
    for r in range(ROWS))

content = f'''<?xml version="1.0" encoding="UTF-8"?>
<office:document-content {NS} office:version="1.2">
<office:body><office:text>
<text:h text:outline-level="1">Annex</text:h>
<text:p>before the giant</text:p>
<table:table table:name="Giant">{'<table:table-column/>' * COLS}{rows}</table:table>
<text:p>after the giant</text:p>
</office:text></office:body></office:document-content>'''

styles = (f'<?xml version="1.0" encoding="UTF-8"?>\n'
          f'<office:document-styles {NS} office:version="1.2"><office:styles/>'
          f'</office:document-styles>')

manifest = '''<?xml version="1.0" encoding="UTF-8"?>
<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">
<manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/>
<manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
<manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>
</manifest:manifest>'''

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with zipfile.ZipFile(OUT, "w") as z:
    # `mimetype` must be first and STORED — that is how an ODF consumer sniffs the type.
    z.writestr(zipfile.ZipInfo("mimetype"), "application/vnd.oasis.opendocument.text",
               compress_type=zipfile.ZIP_STORED)
    z.writestr("META-INF/manifest.xml", manifest)
    z.writestr("content.xml", content)
    z.writestr("styles.xml", styles)

print(f"{OUT}  {os.path.getsize(OUT)} bytes  ({ROWS}x{COLS} = {ROWS * COLS} cells)")
