//! The web app's API (wasm-bindgen); the Mac app's comes from UniFFI.
use crate::invites::SpaceInvite;
use crate::merge::MergeResult;
use crate::sync::{LocalFile, RemoteEntry, SyncAction};
use tsify::{Ts, Tsify};
use wasm_bindgen::prelude::*;

type Js<T> = Result<T, JsError>;

fn actions(actions: Vec<SyncAction>) -> Js<Vec<Ts<SyncAction>>> {
    actions.iter().map(|a| Ok(Ts::from_rust(a)?)).collect()
}

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

#[wasm_bindgen]
#[derive(Default)]
pub struct IgnoreRules(crate::ignore::IgnoreRules);

#[wasm_bindgen]
impl IgnoreRules {
    #[wasm_bindgen(constructor)]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn add(&mut self, dir: &str, content: &str) {
        self.0.add(dir, content);
    }

    #[wasm_bindgen(js_name = isIgnored)]
    pub fn is_ignored(&self, path: &str, is_dir: bool) -> bool {
        self.0.is_ignored(path, is_dir)
    }

    pub fn matches(&self, path: &str, is_dir: bool) -> bool {
        self.0.matches(path, is_dir)
    }
}

#[wasm_bindgen]
pub struct SpaceSync(crate::sync::SpaceSync);

#[wasm_bindgen]
impl SpaceSync {
    #[wasm_bindgen(constructor)]
    pub fn new(lfs_threshold: Option<f64>) -> Self {
        Self(crate::sync::SpaceSync::new(lfs_threshold.unwrap_or(crate::sync::DEFAULT_LFS_THRESHOLD)))
    }

    #[wasm_bindgen(getter = lfsThreshold)]
    pub fn lfs_threshold(&self) -> f64 {
        self.0.lfs_threshold
    }

    #[wasm_bindgen(setter = lfsThreshold)]
    pub fn set_lfs_threshold(&mut self, bytes: f64) {
        self.0.lfs_threshold = bytes;
    }

    pub fn load(&mut self, state: &str) {
        self.0.load(state);
    }

    pub fn save(&self) -> String {
        self.0.save()
    }

    #[wasm_bindgen(getter = syncedPaths)]
    pub fn synced_paths(&self) -> Vec<String> {
        self.0.synced_paths()
    }

    pub fn scan(&mut self, files: Vec<Ts<LocalFile>>, ignore: &IgnoreRules) -> Js<Vec<Ts<SyncAction>>> {
        let files = files.iter().map(Ts::to_rust).collect::<Result<Vec<_>, _>>()?;
        actions(self.0.scan(&files, &ignore.0))
    }

    pub fn remote(
        &mut self,
        entry: Ts<RemoteEntry>,
        local: Option<Ts<LocalFile>>,
        ignore: &IgnoreRules,
        #[wasm_bindgen(unchecked_param_type = "(path: string) => boolean")] exists: &js_sys::Function,
    ) -> Js<Vec<Ts<SyncAction>>> {
        let local = local.map(|l| l.to_rust()).transpose()?;
        actions(self.0.remote(&entry.to_rust()?, local.as_ref(), &ignore.0, check(exists)))
    }

    #[wasm_bindgen(js_name = mergeFailed)]
    pub fn merge_failed(
        &mut self,
        path: &str,
        remote_hash: &str,
        size: f64,
        #[wasm_bindgen(unchecked_param_type = "(path: string) => boolean")] exists: &js_sys::Function,
    ) -> Js<Vec<Ts<SyncAction>>> {
        actions(self.0.merge_failed(path, remote_hash, size, check(exists)))
    }

    pub fn merged(&mut self, path: &str, remote_hash: &str) {
        self.0.merged(path, remote_hash);
    }

    pub fn accepted(&mut self, path: &str, hash: &str) {
        self.0.accepted(path, hash);
    }

    pub fn wrote(&mut self, path: &str, hash: &str, ok: bool) {
        self.0.wrote(path, hash, ok);
    }

    pub fn published(&mut self, path: &str, hash: &str, deleted: bool) {
        self.0.published(path, hash, deleted);
    }
}
