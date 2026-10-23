use std::collections::HashMap;

use typst::diag::{FileResult, Severity, SourceDiagnostic};
use typst::foundations::{Bytes, Datetime, Duration};
use typst::syntax::{FileId, LinkedNode, Side, Source, SyntaxKind, VirtualRoot};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::{Library, World, WorldExt};
use typst_layout::PagedDocument;

use crate::{DiagnosticJSON, diagnostic, diagnostic_in};

struct RecoveryWorld<'a> {
    base: &'a dyn World,
    sources: HashMap<FileId, Source>,
}

impl World for RecoveryWorld<'_> {
    fn library(&self) -> &LazyHash<Library> { self.base.library() }
    fn book(&self) -> &LazyHash<FontBook> { self.base.book() }
    fn main(&self) -> FileId { self.base.main() }
    fn source(&self, id: FileId) -> FileResult<Source> {
        self.sources.get(&id).cloned().map(Ok).unwrap_or_else(|| self.base.source(id))
    }
    fn file(&self, id: FileId) -> FileResult<Bytes> { self.base.file(id) }
    fn font(&self, index: usize) -> Option<Font> { self.base.font(index) }
    fn today(&self, offset: Option<Duration>) -> Option<Datetime> { self.base.today(offset) }
}

impl RecoveryWorld<'_> {
    fn skip(&mut self, error: &SourceDiagnostic) -> Option<()> {
        let id = error.span.id()?;
        if *id.root() != VirtualRoot::Project { return None; }
        let source = self.source(id).ok()?;
        let range = self.range(error.span)?;
        let mut node = LinkedNode::new(source.root()).leaf_at(range.start, Side::After)?;
        while node.parent_kind() != Some(SyntaxKind::Markup) {
            node = node.parent()?.clone();
        }
        // Definitions and control flow can affect every later name, so recovery stops there.
        if !matches!(node.kind(), SyntaxKind::Equation | SyntaxKind::FuncCall | SyntaxKind::Ident | SyntaxKind::FieldAccess) {
            return None;
        }
        let mut start = node.offset();
        let end = start + node.len();
        if let Some(hash) = node.prev_sibling().filter(|n| n.kind() == SyntaxKind::Hash) { start = hash.offset(); }
        // Keep byte positions and line breaks so recovered errors map back to the original source.
        let blank: String = source.text()[start..end].bytes().map(|b| if b == b'\n' || b == b'\r' { b as char } else { ' ' }).collect();
        let mut source = source.clone();
        source.edit(start..end, &blank);
        self.sources.insert(id, source);
        Some(())
    }
}

pub(crate) fn collect(world: &dyn World, initial: Vec<SourceDiagnostic>, failed: bool) -> Vec<DiagnosticJSON> {
    let mut result: Vec<_> = initial.iter().map(|d| diagnostic(world, d)).collect();
    if !failed { return result; }
    let mut recovery = RecoveryWorld { base: world, sources: HashMap::new() };
    let mut errors: Vec<_> = initial.into_iter().filter(|d| d.severity == Severity::Error).collect();
    // Bound retries because each pass evaluates the document again.
    for _ in 0..8 {
        let mut changed = false;
        for error in &errors { changed |= recovery.skip(error).is_some(); }
        if !changed { break; }
        let Err(next) = typst::compile::<PagedDocument>(&recovery).output else { break };
        errors = next.into_iter().collect();
        for error in &errors {
            let diagnostic = diagnostic_in(&recovery, world, error);
            if !result.iter().any(|d| d.path == diagnostic.path && d.line == diagnostic.line && d.column == diagnostic.column && d.message == diagnostic.message) {
                result.push(diagnostic);
            }
        }
    }
    result
}
