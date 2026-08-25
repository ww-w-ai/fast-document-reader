//! S3 pass C: `render::markdown::produce`'s image layer (S3-06, the inline half — the `Image`
//! schema field itself and its validation are S3-06's other half, owned elsewhere). This pass
//! carries what the document declared and resolves nothing: no column width, so a `50%` crosses
//! as `displayWidthFraction`, never converted to points (that conversion needs a column, which is
//! S5's concern).

use fastdoc_engine::render::markdown::produce;
use serde_json::Value;

fn tree_json(markdown: &str) -> Value {
    let tree = produce(markdown.as_bytes(), "test.md").unwrap();
    let json = tree.encode_json().unwrap();
    serde_json::from_slice(&json).unwrap()
}

fn nodes_of(markdown: &str) -> Vec<Value> {
    tree_json(markdown)["nodes"].as_array().unwrap().clone()
}

fn nodes_by_tag<'a>(nodes: &'a [Value], tag: &str) -> Vec<&'a Value> {
    nodes.iter().filter(|n| n["type"] == tag).collect()
}

#[test]
fn a_plain_image_reaches_an_image_node_with_a_registered_resource_and_no_declared_size() {
    let source = "![a cat](cat.png)\n";
    let tree = tree_json(source);
    let nodes = tree["nodes"].as_array().unwrap();
    let images = nodes_by_tag(nodes, "image");
    assert_eq!(images.len(), 1, "expected exactly one image node, got {nodes:?}");
    let image = images[0];
    assert_eq!(image["data"]["altText"], "a cat");
    assert_eq!(image["data"]["displaySize"], Value::Null);
    assert_eq!(image["data"]["displayWidthFraction"], Value::Null);

    // `resourceId` must reference a REAL registered resource (`validate.rs`'s `require_resource`
    // — this is why `tree_json`'s round trip through `encode_json`/canonical validation is what
    // this test exercises, not just the raw draft).
    let resource_id = image["data"]["resourceId"].as_u64().unwrap();
    let resources = tree["resources"].as_array().unwrap();
    assert!(
        resources.iter().any(|r| r["id"].as_u64() == Some(resource_id)),
        "image resourceId must resolve to a registered resource, got resources {resources:?}"
    );
}

#[test]
fn an_alt_with_no_size_suffix_is_carried_untouched() {
    let nodes = nodes_of("![just a caption](x.png)\n");
    let images = nodes_by_tag(&nodes, "image");
    assert_eq!(images[0]["data"]["altText"], "just a caption");
    assert_eq!(images[0]["data"]["displaySize"], Value::Null);
}

#[test]
fn a_point_width_alt_suffix_crosses_as_display_size_not_a_fraction() {
    let nodes = nodes_of("![alt|300](x.png)\n");
    let images = nodes_by_tag(&nodes, "image");
    let image = images[0];
    assert_eq!(image["data"]["altText"], "alt", "the |300 suffix must be stripped from the alt");
    assert_eq!(image["data"]["displaySize"]["width"], 300.0);
    assert_eq!(image["data"]["displayWidthFraction"], Value::Null);
}

#[test]
fn a_percent_width_alt_suffix_crosses_as_a_fraction_never_resolved_to_points() {
    let nodes = nodes_of("![alt|50%](x.png)\n");
    let images = nodes_by_tag(&nodes, "image");
    let image = images[0];
    assert_eq!(image["data"]["altText"], "alt");
    assert_eq!(image["data"]["displayWidthFraction"], 0.5);
    assert_eq!(
        image["data"]["displaySize"],
        Value::Null,
        "a declared percent must never be resolved to an absolute point size in this pass"
    );
}

#[test]
fn two_images_with_the_same_src_share_one_registered_resource() {
    let tree = tree_json("![one](x.png)\n\n![two](x.png)\n");
    let nodes = tree["nodes"].as_array().unwrap();
    let images = nodes_by_tag(nodes, "image");
    assert_eq!(images.len(), 2);
    let id_a = images[0]["data"]["resourceId"].as_u64().unwrap();
    let id_b = images[1]["data"]["resourceId"].as_u64().unwrap();
    assert_eq!(id_a, id_b, "the same declared src must dedupe to one resource");
    let resources = tree["resources"].as_array().unwrap();
    assert_eq!(resources.len(), 1, "expected exactly one registered resource, got {resources:?}");
}

/// The producer does not read image bytes, so it cannot know a picture's real size — and the wire
/// schema has no "unresolved" resource shape to say so with. What it emits instead is a resource
/// whose content is the DECLARED SRC (`text/uri-list`, RFC 2483) and an `intrinsicSize` of exactly
/// zero.
///
/// `valid_size` accepts zero (`validate.rs`: `finite_nonnegative`), so nothing downstream is forced
/// to notice, and a consumer that reads `{0, 0}` as a measured size would lay out an invisible
/// image and never report why. This test exists to make that shape a STATED contract rather than an
/// accident: when a later sprint resolves images for real, this test fails, and updating it is how
/// the change gets acknowledged instead of slipping through.
#[test]
fn an_unresolved_image_says_so_in_its_resource_and_its_zero_intrinsic_size() {
    let tree = tree_json("![a cat](cat.png)\n");
    let nodes = tree["nodes"].as_array().unwrap();
    let image = nodes_by_tag(nodes, "image")[0];

    assert_eq!(
        image["data"]["intrinsicSize"]["width"], 0.0,
        "zero width is the sentinel for 'not resolved', not a measurement"
    );
    assert_eq!(image["data"]["intrinsicSize"]["height"], 0.0);

    let resource_id = image["data"]["resourceId"].as_u64().unwrap();
    let resource = tree["resources"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["id"].as_u64() == Some(resource_id))
        .expect("the image's resource is registered");
    assert_eq!(
        resource["mimeType"], "text/uri-list",
        "the registered bytes are the declared src, not the picture — the mime type has to say so"
    );
}

