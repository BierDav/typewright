//! The web app's API (wasm-bindgen); the Mac app's comes from UniFFI.
use crate::invites::SpaceInvite;
use crate::line_editing::{LineChange, LineSelection};
use crate::merge::MergeResult;
use crate::shares::{PeerHead, SharePath, SharePlace, ShareStatus};
use tsify::{Ts, Tsify};
use wasm_bindgen::prelude::*;

type Js<T> = Result<T, JsError>;

fn check(f: &js_sys::Function) -> impl Fn(&str) -> bool {
    |path| f.call1(&JsValue::NULL, &JsValue::from_str(path)).is_ok_and(|v| v.is_truthy())
}

/// The kind's id (`"typst"`, `"text"`, …) for a known extension; the caller sniffs others.
#[wasm_bindgen(js_name = fileKindForExtension)]
pub fn file_kind_for_extension(ext: &str) -> Option<String> {
    crate::files::file_kind_for_extension(ext).map(|kind| kind.name().to_string())
}

#[wasm_bindgen(js_name = spaceRelativePath)]
pub fn space_relative_path(path: &str, root: &str) -> Option<String> {
    crate::files::space_relative_path(path, root)
}

#[wasm_bindgen(js_name = uniqueName)]
pub fn unique_name(
    name: &str,
    ext: Option<String>,
    #[wasm_bindgen(unchecked_param_type = "(name: string) => boolean")] exists: &js_sys::Function,
) -> String {
    crate::files::unique_name(name, ext.as_deref(), check(exists))
}

#[wasm_bindgen(js_name = spaceOrderAdd)]
pub fn space_order_add(stored: Vec<String>, path: String) -> Vec<String> {
    crate::spaces::space_order_add(stored, path)
}

#[wasm_bindgen(js_name = spaceOrderMove)]
pub fn space_order_move(stored: Vec<String>, visible: Vec<String>, path: &str, index: i32) -> Vec<String> {
    crate::spaces::space_order_move(stored, visible, path, index)
}

#[wasm_bindgen(js_name = spaceOrderReplace)]
pub fn space_order_replace(stored: Vec<String>, old: &str, new: &str) -> Vec<String> {
    crate::spaces::space_order_replace(stored, old, new)
}

#[wasm_bindgen(js_name = fuzzyScore)]
pub fn fuzzy_score(query: &str, text: &str) -> Option<i32> {
    crate::spaces::fuzzy_score(query, text)
}

#[wasm_bindgen(js_name = codeLanguage)]
pub fn code_language(tag: &str) -> Option<String> {
    crate::highlight::code_language(tag)
}

#[wasm_bindgen(js_name = rawBlockParts)]
pub fn raw_block_parts(raw: &str) -> Vec<i32> {
    crate::highlight::raw_block_parts(raw)
}

#[wasm_bindgen(js_name = codeTokens)]
pub fn code_tokens(language: &str, code: &str) -> Vec<i32> {
    crate::highlight::code_tokens(language, code)
}

#[wasm_bindgen(js_name = inviteLink)]
pub fn invite_link(invite: Ts<SpaceInvite>) -> Js<Option<String>> {
    Ok(crate::invites::invite_link(invite.to_rust()?))
}

#[wasm_bindgen(js_name = webInviteLink)]
pub fn web_invite_link(link: &str, web_app: Option<String>) -> Option<String> {
    crate::invites::web_invite_link(link, web_app)
}

#[wasm_bindgen(js_name = parseInvite)]
pub fn parse_invite(link: &str) -> Js<Option<Ts<SpaceInvite>>> {
    Ok(crate::invites::parse_invite(link).map(|i| i.into_ts()).transpose()?)
}

#[wasm_bindgen]
pub fn merge3(base: &str, local: &str, remote: &str) -> Js<Ts<MergeResult>> {
    Ok(crate::merge::merge3(base, local, remote).into_ts()?)
}

/// Line diff from `old` to `new`, as runs of same, added and removed lines.
#[wasm_bindgen(js_name = lineDiff)]
pub fn line_diff(old: &str, new: &str) -> Js<Vec<Ts<crate::diff::DiffHunk>>> {
    crate::diff::line_diff(old, new).into_iter().map(|h| Ok(h.into_ts()?)).collect()
}

fn shares(shares: Vec<Ts<SharePath>>) -> Js<Vec<SharePath>> {
    shares.iter().map(|s| Ok(s.to_rust()?)).collect()
}

/// The innermost share holding the repository `path`, with the path inside it (as live sessions name files).
#[wasm_bindgen(js_name = sharePlace)]
pub fn share_place(list: Vec<Ts<SharePath>>, path: &str) -> Js<Option<Ts<SharePlace>>> {
    Ok(match crate::shares::share_place(shares(list)?, path) {
        Some(place) => Some(Ts::from_rust(&place)?),
        None => None,
    })
}

/// The repository path of `inside` (as `sharePlace` names it) in a share.
#[wasm_bindgen(js_name = shareFilePath)]
pub fn share_file_path(share: Ts<SharePath>, inside: &str) -> Js<String> {
    Ok(crate::shares::share_file_path(share.to_rust()?, inside))
}

/// Ids of the shares any of the commit's `changed` repository paths touch.
#[wasm_bindgen(js_name = sharesTouched)]
pub fn shares_touched(list: Vec<Ts<SharePath>>, changed: Vec<String>) -> Js<Vec<String>> {
    Ok(crate::shares::shares_touched(shares(list)?, changed))
}

/// Whether a remote head is news: neither this device's node nor one of its ancestors.
#[wasm_bindgen(js_name = needsMerge)]
pub fn needs_merge(head: Option<String>, ancestry: Vec<String>, remote: &str) -> bool {
    crate::shares::needs_merge(head, ancestry, remote)
}

#[wasm_bindgen(js_name = shareStatus)]
pub fn share_status(head: Option<String>, peers: Vec<Ts<PeerHead>>, others: u32, conflicted: bool, working: bool) -> Js<Ts<ShareStatus>> {
    let peers = peers.iter().map(Ts::to_rust).collect::<Result<Vec<_>, _>>()?;
    Ok(Ts::from_rust(&crate::shares::share_status(head, peers, others, conflicted, working))?)
}

/// `owner/repo` when the input names a GitHub repository.
#[wasm_bindgen(js_name = packageGithubRepo)]
pub fn package_github_repo(input: &str) -> Option<String> {
    crate::packages::package_github_repo(input)
}

/// The `<name>/<version>` package folders of a repository that is a whole namespace.
#[wasm_bindgen(js_name = namespacePackages)]
pub fn namespace_packages(paths: Vec<String>) -> Vec<String> {
    crate::packages::namespace_packages(&paths)
}

/// Name and version of a `typst.toml`'s `[package]` table.
#[wasm_bindgen(js_name = packageManifest)]
pub fn package_manifest(toml: &str) -> Js<Option<Ts<crate::packages::PackageManifest>>> {
    Ok(crate::packages::package_manifest(toml).map(|m| m.into_ts()).transpose()?)
}

/// Enter with `from..to` selected, in `"typst"`, `"markdown"` or plain text: indentation, brackets and list items.
#[wasm_bindgen]
pub fn newline(text: &str, from: i32, to: i32, syntax: &str) -> Js<Ts<crate::typing::Typing>> {
    Ok(Ts::from_rust(&crate::typing::newline(text, from, to, syntax))?)
}

/// Backspace at `caret`: empty pairs of `pairs` go together, indentation back to where it belongs and the line break.
#[wasm_bindgen]
pub fn backspace(text: &str, caret: i32, pairs: &str) -> Js<Option<Ts<crate::typing::Typing>>> {
    Ok(crate::typing::backspace(text, caret, pairs).map(|t| Ts::from_rust(&t)).transpose()?)
}

fn selections(list: Vec<Ts<LineSelection>>) -> Js<Vec<LineSelection>> {
    list.iter().map(|s| Ok(s.to_rust()?)).collect()
}

fn line_change(change: LineChange) -> Js<Ts<LineChange>> {
    Ok(Ts::from_rust(&change)?)
}

#[wasm_bindgen(js_name = copyCurrentLines)]
pub fn copy_current_lines(offsets: Vec<i32>, text: &str) -> String {
    crate::line_editing::copy_current_lines(offsets, text)
}

#[wasm_bindgen(js_name = cutCurrentLines)]
pub fn cut_current_lines(offsets: Vec<i32>, text: &str) -> Js<Ts<LineChange>> {
    line_change(crate::line_editing::cut_current_lines(offsets, text))
}

#[wasm_bindgen(js_name = moveSelectedLines)]
pub fn move_selected_lines(list: Vec<Ts<LineSelection>>, up: bool, text: &str) -> Js<Ts<LineChange>> {
    line_change(crate::line_editing::move_selected_lines(selections(list)?, up, text))
}

#[wasm_bindgen(js_name = deleteSelectedLines)]
pub fn delete_selected_lines(list: Vec<Ts<LineSelection>>, text: &str) -> Js<Ts<LineChange>> {
    line_change(crate::line_editing::delete_selected_lines(selections(list)?, text))
}

#[wasm_bindgen(js_name = duplicateSelectedLines)]
pub fn duplicate_selected_lines(list: Vec<Ts<LineSelection>>, text: &str) -> Js<Ts<LineChange>> {
    line_change(crate::line_editing::duplicate_selected_lines(selections(list)?, text))
}
