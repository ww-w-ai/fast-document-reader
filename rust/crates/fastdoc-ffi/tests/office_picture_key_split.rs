//! P2c — no picture the DOCUMENT named travels inside the payload.
//!
//! P2a made a resource legal without bytes provided it carries a `source_key`, and P2b gave the
//! host a way to fetch one picture from the still-open parse. Both only apply to a resource the
//! DOCUMENT named: a table/cell picture FILL is decoded during the mapping walk and never had a
//! document-declared id, so it has no key to be fetched by and its bytes have to travel.
//!
//! Measured before P2c on the 편람: 66 keyed resources against 127 total, which reads as "half the
//! pictures cannot go lazy". Counts are the wrong unit — the payload is measured in BYTES, and in
//! bytes the keyed half was 50,774,496 of 53,937,512 (94.1%). That is what P2c removes; the
//! anonymous 5.9% stays, and the assertions below say so rather than rounding it away.
//!
//! This doubles as P2c's own gate, and it is deliberately stated over the OUTPUT rather than over
//! an instrumented counter: "no picture was decoded at read" is a claim about work, which a
//! counter can be made to report while the work still happens. "No keyed resource carries bytes"
//! is a fact about the bytes a host actually receives, and it cannot be true while they do.
//!
//!     FMD_PICTURE_KEY_SPLIT=<document> cargo test -p fastdoc-ffi \
//!       --test office_picture_key_split -- --nocapture

use std::ffi::{CStr, CString};
use std::path::PathBuf;

fn resolve(path: &str) -> PathBuf {
    let p = PathBuf::from(path);
    if p.is_absolute() {
        return p;
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..").join(p)
}

#[test]
fn how_many_picture_bytes_carry_a_document_declared_key() {
    let Ok(path) = std::env::var("FMD_PICTURE_KEY_SPLIT") else {
        eprintln!("skipped: set FMD_PICTURE_KEY_SPLIT to a document path");
        return;
    };
    let path = resolve(&path);
    let data = std::fs::read(&path).expect("readable document");
    let ext = CString::new(path.extension().unwrap().to_str().unwrap()).unwrap();
    let json = unsafe {
        fastdoc_engine_ffi::fastdoc_read_office_tree(data.as_ptr(), data.len(), ext.as_ptr())
    };
    assert!(!json.is_null(), "the engine refused {}", path.display());
    let owned = unsafe { CStr::from_ptr(json) }.to_string_lossy().into_owned();
    unsafe { fastdoc_engine_ffi::fastdoc_string_free(json) };

    let value: serde_json::Value = serde_json::from_str(&owned).expect("tree is JSON");
    let resources = value
        .get("ok")
        .and_then(|o| o.get("resources"))
        .and_then(|r| r.as_array())
        .expect("the tree has a resource table");

    let (mut keyed_n, mut keyed_b, mut anon_n, mut anon_b) = (0usize, 0usize, 0usize, 0usize);
    for r in resources {
        let bytes = r
            .get("bytesBase64")
            .and_then(serde_json::Value::as_str)
            .map(str::len)
            .unwrap_or(0);
        let keyed = r
            .get("sourceKey")
            .and_then(serde_json::Value::as_str)
            .is_some_and(|k| !k.trim().is_empty());
        if keyed {
            keyed_n += 1;
            keyed_b += bytes;
        } else {
            anon_n += 1;
            anon_b += bytes;
        }
    }
    let total = keyed_b + anon_b;
    // Vacuity guard: a document with no pictures satisfies "no keyed bytes" while measuring
    // nothing, and this census is only meaningful on one that HAS pictures.
    assert!(
        keyed_n > 0,
        "{} declares no keyed picture at all, so it proves nothing about P2c",
        path.display()
    );
    assert_eq!(
        keyed_b, 0,
        "{}: {keyed_b} bytes of picture still travel inside the payload under {keyed_n} \
         document-declared keys. Every one of those is fetchable on demand \
         (`fastdoc_office_image_base64`), which is the whole of P2c.",
        path.display()
    );
    println!(
        "SPLIT {} picture-bytes total={total} keyed={keyed_b} ({keyed_n} resources) \
         anonymous={anon_b} ({anon_n} resources — table fills and anchored objects, which carry \
         pixels in the vocabulary itself and have no key to be fetched by)",
        path.display(),
    );
}
