//! P2b/P2c — the picture a host fetches on demand is the picture the reader used to be handed.
//!
//! An `.hwp` is CFB binary, so its pictures are reachable only through the rhwp parse that produced
//! the document. Until P2b that parse closed at the read's end, which is why the read decoded every
//! picture up front and shipped them all inside the payload. P2b keeps it open; P2c stops shipping
//! them. The whole trade rests on one property: **the picture fetched later is byte-identical to
//! the picture that used to be embedded.** Not "a valid image", not "the right size" — the same
//! bytes, or the reader draws something the document does not say.
//!
//! ## Why recorded hashes, and not a comparison against the read
//!
//! While the read still embedded pictures, this test compared the fetch against `images` in the
//! export — a genuinely independent oracle, and it immediately caught a cropped occurrence coming
//! back UNCROPPED. After P2c that export carries no pictures, so the same comparison would compare
//! the resolver against itself and pass on anything.
//!
//! So the answers were RECORDED at the last commit that still embedded them (`b24d24c`, where the
//! equality was proven rather than assumed) and are pinned below. A recorded hash is an oracle no
//! later change to the resolver can move on its own — which is the property the comparison had and
//! a self-comparison does not.
//!
//! A cropped picture is pinned deliberately: that is the axis the one real defect lived on.

use std::ffi::{CStr, CString};
use std::path::PathBuf;

use sha2::{Digest, Sha256};

/// `(document, picture key, sha256 of its bytes, byte length)`, recorded at `b24d24c` from the
/// pictures the read placed in `OfficeReadResult.images`.
///
/// Re-record ONLY when the pictures themselves are meant to change (a different rhwp, a different
/// crop rule) — and say so in the commit, because a silent re-record turns this file back into a
/// self-comparison. `FMD_RECORD_PICTURE_HASHES=1` prints replacement lines.
const RECORDED: &[(&str, &str, &str, usize)] = &[
    (
        "textbox-under-image.hwp",
        "hwpimg:1!crop=0,0,0.2143167447024183,0.2143205065757428",
        "54defd30552a08719c3b2b8d56460e6ef29c26cc10d080baf017a395a4171b74",
        280,
    ),
    (
        "test-image.hwp",
        "hwpimg:1",
        "dfc98c6df0f7cbbf7ae253a1e0a32fda732b3f2a0c0093fb4867bc52a779a9ea",
        128_526,
    ),
    (
        "test-image.hwpx",
        "hwpimg:1",
        "dfc98c6df0f7cbbf7ae253a1e0a32fda732b3f2a0c0093fb4867bc52a779a9ea",
        128_526,
    ),
];

fn samples_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../Vendor/rhwp-src/samples")
}

fn open(path: &PathBuf) -> Option<*mut fastdoc_engine_ffi::FastdocOfficeDocument> {
    let data = std::fs::read(path).ok()?;
    let ext = CString::new(path.extension()?.to_str()?).ok()?;
    let handle = unsafe {
        fastdoc_engine_ffi::fastdoc_office_open(data.as_ptr(), data.len(), ext.as_ptr())
    };
    (!handle.is_null()).then_some(handle)
}

fn fetch(
    handle: *mut fastdoc_engine_ffi::FastdocOfficeDocument,
    key: &str,
) -> Option<Vec<u8>> {
    let key_c = CString::new(key).ok()?;
    let fetched =
        unsafe { fastdoc_engine_ffi::fastdoc_office_image_base64(handle, key_c.as_ptr()) };
    if fetched.is_null() {
        return None;
    }
    let base64 = unsafe { CStr::from_ptr(fetched) }.to_string_lossy().into_owned();
    unsafe { fastdoc_engine_ffi::fastdoc_string_free(fetched) };
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.decode(&base64).ok()
}

#[test]
fn a_picture_fetched_from_the_open_parse_is_the_one_the_read_used_to_embed() {
    let mut checked = 0usize;
    let mut cropped = 0usize;
    for (file, key, sha, len) in RECORDED {
        let path = samples_dir().join(file);
        let handle = open(&path)
            .unwrap_or_else(|| panic!("{}: the engine could not open this sample", path.display()));
        let bytes = fetch(handle, key).unwrap_or_else(|| {
            panic!("{}: the open parse produced nothing for {key}", path.display())
        });
        unsafe { fastdoc_engine_ffi::fastdoc_office_close(handle) };
        assert_eq!(
            bytes.len(),
            *len,
            "{}: {key} is {} bytes, recorded as {len}",
            path.display(),
            bytes.len()
        );
        assert_eq!(
            format!("{:x}", Sha256::digest(&bytes)),
            *sha,
            "{}: {key} is not the picture recorded for it",
            path.display()
        );
        checked += 1;
        if key.contains("!crop=") {
            cropped += 1;
        }
    }
    // Coverage, asserted rather than hoped for: a table trimmed down to uncropped pictures would
    // still pass every assertion above while no longer covering the crop rule, which is the one
    // thing here that has actually been got wrong.
    assert_eq!(checked, RECORDED.len(), "not every recorded picture was checked");
    assert!(cropped >= 1, "no CROPPED picture is pinned — the defect this file exists for would pass");
}

/// A key nobody declared answers NULL rather than something a caller could mistake for a picture.
#[test]
fn a_key_this_document_does_not_have_answers_nothing() {
    let path = samples_dir().join(RECORDED[1].0);
    let Some(handle) = open(&path) else { panic!("{}: could not open", path.display()) };
    for key in ["hwpimg:65000", "not-a-key", "hwpimg:", "hwpimg:abc"] {
        assert!(fetch(handle, key).is_none(), "{key} answered something");
    }
    unsafe { fastdoc_engine_ffi::fastdoc_office_close(handle) };
}
