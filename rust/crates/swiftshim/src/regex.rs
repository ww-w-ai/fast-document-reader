//! swift: markdown/HTML-attribute pattern matching in MarkdownRenderer.swift and
//! OfficeMarkdownSerializer.swift — `NSRegularExpression(pattern:options:)`,
//! `.firstMatch(in:range:)`, `.range(at:)`, plus one `NSDataDetector` link scan.

use crate::foundation::NSRange;

/// swift: NSRegularExpression.Options
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct NSRegularExpressionOptions(pub u32);

impl NSRegularExpressionOptions {
    pub const caseInsensitive: NSRegularExpressionOptions = NSRegularExpressionOptions(1);
}

/// swift: NSRegularExpression
#[derive(Debug, Clone)]
pub struct NSRegularExpression {
    pub pattern: String,
    pub options: NSRegularExpressionOptions,
}

impl NSRegularExpression {
    pub fn new(
        pattern: &str,
        options: NSRegularExpressionOptions,
    ) -> Result<Self, crate::foundation::EngineError> {
        Ok(Self {
            pattern: pattern.to_string(),
            options,
        })
    }

    pub fn firstMatch(&self, _in_string: &str, _range: NSRange) -> Option<NSTextCheckingResult> {
        todo!("swift: NSRegularExpression.firstMatch(in:options:range:) — phase B (needs ICU regex)")
    }

    pub fn matches(&self, _in_string: &str, _range: NSRange) -> Vec<NSTextCheckingResult> {
        todo!("swift: NSRegularExpression.matches(in:options:range:) — phase B (needs ICU regex)")
    }

    pub fn numberOfMatches(&self, _in_string: &str, _range: NSRange) -> usize {
        todo!("swift: NSRegularExpression.numberOfMatches(in:options:range:) — phase B")
    }
}

/// swift: NSTextCheckingResult
#[derive(Debug, Clone)]
pub struct NSTextCheckingResult {
    pub range: NSRange,
    group_ranges: Vec<Option<NSRange>>,
}

impl NSTextCheckingResult {
    pub fn range(&self, at: usize) -> NSRange {
        self.group_ranges
            .get(at)
            .and_then(|r| *r)
            .unwrap_or_else(NSRange::notFound)
    }
}

/// swift: NSDataDetector — a specialised `NSRegularExpression` subclass (link/date detection);
/// the in-scope call site uses it only for links, so it is modeled as its own thin type rather
/// than inheriting `NSRegularExpression`'s fields.
#[derive(Debug, Clone, Default)]
pub struct NSDataDetector;

impl NSDataDetector {
    pub fn linkDetector() -> Result<Self, crate::foundation::EngineError> {
        todo!("swift: NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) — phase B")
    }

    pub fn firstMatch(&self, _in_string: &str, _range: NSRange) -> Option<NSTextCheckingResult> {
        todo!("swift: NSDataDetector.firstMatch(in:options:range:) — phase B")
    }
}
