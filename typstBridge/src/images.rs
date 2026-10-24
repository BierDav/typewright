//! Large images in preview HTML: typst embeds them as base64 `data:` URLs, which every update would copy,
//! send to the web view and parse again. They are swapped for `twimage:` URLs the preview loads from here.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Arc, LazyLock};

use base64::Engine;
use parking_lot::Mutex;
use typst::diag::SourceResult;
use typst::ecow::EcoString;
use typst_html::{HtmlDocument, HtmlElement, HtmlNode, HtmlOptions, attr, tag};

pub const SCHEME: &str = "twimage";
/// Smaller images cost less inline than a request.
const MIN_PAYLOAD: usize = 8 * 1024;
/// Outputs whose images stay available, since the page may still show an older one while newer ones compile.
const KEPT_OUTPUTS: usize = 3;
/// Which bytes can appear in base64.
const BASE64: [bool; 256] = {
    let mut table = [false; 256];
    let mut i = 0;
    while i < 256 {
        let b = i as u8;
        table[i] = b.is_ascii_alphanumeric() || b == b'+' || b == b'/' || b == b'=';
        i += 1;
    }
    table
};

struct Entry {
    mime: String,
    base64: Arc<[u8]>,
    uses: usize,
}

#[derive(Default)]
struct Store {
    entries: HashMap<u64, Entry>,
    /// Ids by payload length and a hash of its ends, so a known image is found without hashing all of it.
    shapes: HashMap<(usize, u64), Vec<u64>>,
    next: u64,
}

static STORE: LazyLock<Mutex<Store>> = LazyLock::new(Default::default);

fn shape(payload: &[u8]) -> (usize, u64) {
    let ends = 1024.min(payload.len());
    let hash = typst::utils::hash128(&(&payload[..ends], &payload[payload.len() - ends..])) as u64;
    (payload.len(), hash)
}

impl Store {
    fn intern(&mut self, mime: &str, payload: &[u8]) -> u64 {
        let key = shape(payload);
        let known = self.shapes.get(&key).into_iter().flatten()
            .find(|id| self.entries.get(id).is_some_and(|e| e.mime == mime && *e.base64 == *payload));
        if let Some(&id) = known {
            return id;
        }
        self.next += 1;
        let id = self.next;
        self.entries.insert(id, Entry { mime: mime.into(), base64: payload.into(), uses: 0 });
        self.shapes.entry(key).or_default().push(id);
        id
    }

    fn release(&mut self, ids: &HashSet<u64>) {
        for id in ids {
            let Some(entry) = self.entries.get_mut(id) else { continue };
            entry.uses -= 1;
            if entry.uses == 0 {
                let key = shape(&entry.base64);
                self.entries.remove(id);
                if let Some(ids) = self.shapes.get_mut(&key) {
                    ids.retain(|other| other != id);
                    if ids.is_empty() {
                        self.shapes.remove(&key);
                    }
                }
            }
        }
    }
}

/// The images of one preview's recent outputs.
#[derive(Default)]
pub struct PreviewImages {
    outputs: VecDeque<HashSet<u64>>,
}

impl PreviewImages {
    /// Replaces large `data:` URLs with `twimage:///<mime>/<id>`.
    pub fn rewrite(&mut self, html: &[u8]) -> Vec<u8> {
        let mut used = HashSet::new();
        let out = rewrite_text(&mut STORE.lock(), html, &mut used);
        self.finish(used);
        out
    }

    /// Writes a document's HTML for the preview. Its images are swapped before typst writes them, which
    /// would otherwise escape every byte of their base64 again; those in frames are swapped after.
    pub fn html(&mut self, doc: &mut HtmlDocument) -> SourceResult<Vec<u8>> {
        let mut used = HashSet::new();
        let mut paths = Vec::new();
        image_paths(doc.root(), &mut Vec::new(), &mut paths);
        if !paths.is_empty() {
            let mut store = STORE.lock();
            for path in &paths {
                swap_image(&mut store, doc.root_mut(), path, &mut used);
            }
        }
        let html = typst_html::html(doc, &HtmlOptions::default())?;
        let out = rewrite_text(&mut STORE.lock(), html.as_bytes(), &mut used);
        self.finish(used);
        Ok(out)
    }

    fn finish(&mut self, used: HashSet<u64>) {
        let mut store = STORE.lock();
        for id in &used {
            store.entries.get_mut(id).expect("interned").uses += 1;
        }
        self.outputs.push_back(used);
        while self.outputs.len() > KEPT_OUTPUTS {
            let old = self.outputs.pop_front().expect("not empty");
            store.release(&old);
        }
    }
}

/// The URL standing for a large image, or none for small ones.
fn image_url(store: &mut Store, mime: &str, payload: &[u8], used: &mut HashSet<u64>) -> Option<String> {
    if payload.len() < MIN_PAYLOAD {
        return None;
    }
    let id = store.intern(mime, payload);
    used.insert(id);
    Some(format!("{SCHEME}:///{mime}/{id}"))
}

fn rewrite_text(store: &mut Store, html: &[u8], used: &mut HashSet<u64>) -> Vec<u8> {
    let mut out = Vec::with_capacity(html.len().min(1 << 20));
    let mut rest = 0;
    for start in memchr::memmem::find_iter(html, b"data:") {
        if start < rest {
            continue;
        }
        let Some((mime, payload, len)) = data_url(&html[start..]) else { continue };
        let Some(url) = image_url(store, mime, payload, used) else { continue };
        out.extend_from_slice(&html[rest..start]);
        out.extend_from_slice(url.as_bytes());
        rest = start + len;
    }
    out.extend_from_slice(&html[rest..]);
    out
}

fn large_src(element: &HtmlElement) -> Option<&EcoString> {
    let src = element.attrs.get(attr::src)?;
    (element.tag == tag::img && src.len() >= MIN_PAYLOAD && src.starts_with("data:")).then_some(src)
}

/// Child indices leading to every `<img>` with a large `data:` source; only those paths are copied to change them.
fn image_paths(element: &HtmlElement, path: &mut Vec<usize>, out: &mut Vec<Vec<usize>>) {
    if large_src(element).is_some() {
        out.push(path.clone());
    }
    for (i, child) in element.children.iter().enumerate() {
        if let HtmlNode::Element(child) = child {
            path.push(i);
            image_paths(child, path, out);
            path.pop();
        }
    }
}

fn swap_image(store: &mut Store, mut element: &mut HtmlElement, path: &[usize], used: &mut HashSet<u64>) {
    for &i in path {
        let HtmlNode::Element(child) = &mut element.children.make_mut()[i] else { return };
        element = child;
    }
    let Some(src) = large_src(element) else { return };
    let url = match data_url(src.as_bytes()) {
        Some((mime, payload, len)) if len == src.len() => image_url(store, mime, payload, used),
        _ => None,
    };
    if let Some(url) = url {
        *element.attrs.get_mut(attr::src).expect("checked") = url.into();
    }
}

impl Drop for PreviewImages {
    fn drop(&mut self) {
        let mut store = STORE.lock();
        for ids in self.outputs.drain(..) {
            store.release(&ids);
        }
    }
}

/// `data:<mime>;base64,<payload>` at the start of `text`, for image types only, and the URL's length.
fn data_url(text: &[u8]) -> Option<(&str, &[u8], usize)> {
    let head = &text[5..text.len().min(5 + 64)];
    let semicolon = memchr::memchr(b';', head)?;
    let mime = std::str::from_utf8(&head[..semicolon]).ok()?;
    let valid = mime.strip_prefix("image/")
        .is_some_and(|sub| !sub.is_empty() && sub.bytes().all(|b| b.is_ascii_alphanumeric() || b"+-.".contains(&b)));
    if !valid || !head[semicolon..].starts_with(b";base64,") {
        return None;
    }
    let offset = 5 + semicolon + 8;
    let body = &text[offset..];
    let end = body.iter().position(|&b| !BASE64[b as usize]).unwrap_or(body.len());
    Some((mime, &body[..end], offset + end))
}

/// The decoded bytes of an image in a recent output.
pub fn image(id: u64) -> Option<Vec<u8>> {
    let base64 = STORE.lock().entries.get(&id)?.base64.clone();
    base64::engine::general_purpose::STANDARD.decode(&*base64).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn payload(seed: u8) -> String {
        let bytes: Vec<u8> = (0..20_000u32).map(|i| (i as u8).wrapping_mul(seed)).collect();
        base64::engine::general_purpose::STANDARD.encode(bytes)
    }

    #[test]
    fn swaps_large_images_and_keeps_recent_outputs() {
        let (a, b) = (payload(3), payload(5));
        let html = format!(r#"<img src="data:image/png;base64,{a}"><svg><image href="data:image/jpeg;base64,{b}"/></svg><img src="data:image/png;base64,AAAA">"#);
        let mut images = PreviewImages::default();
        let out = String::from_utf8(images.rewrite(html.as_bytes())).unwrap();
        let ids: Vec<u64> = out.match_indices("twimage:///").map(|(i, _)| {
            out[i..].split(['"', '/']).nth(5).unwrap().parse().unwrap()
        }).collect();
        assert_eq!(ids.len(), 2, "{out}");
        assert!(out.contains("twimage:///image/png/") && out.contains("twimage:///image/jpeg/"));
        assert!(out.contains("data:image/png;base64,AAAA"), "small images stay inline");
        assert_eq!(image(ids[0]).unwrap(), base64::engine::general_purpose::STANDARD.decode(&a).unwrap());

        // The same image keeps its URL, so the page doesn't load it again.
        assert_eq!(String::from_utf8(images.rewrite(html.as_bytes())).unwrap(), out);
        for _ in 0..KEPT_OUTPUTS {
            images.rewrite(b"<p>none</p>");
        }
        assert!(image(ids[0]).is_none(), "images no output uses are dropped");
    }

    #[test]
    fn world_html_references_images() {
        let dir = std::env::temp_dir().join(format!("tw-images-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // A PNG of noise: 64×64 RGB, stored uncompressed, so it stays above the inline limit.
        let raw: Vec<u8> = (0..64u32).flat_map(|y| std::iter::once(0).chain((0..192u32).map(move |x| (x * 7 + y * 13) as u8))).collect();
        let png = png_bytes(64, 64, &raw);
        std::fs::write(dir.join("photo.png"), &png).unwrap();
        std::fs::write(dir.join("main.typ"), "#image(\"photo.png\")").unwrap();
        let (root, main) = (std::ffi::CString::new(dir.to_str().unwrap()).unwrap(), std::ffi::CString::new("main.typ").unwrap());
        unsafe {
            let world = crate::tw_world_new(root.as_ptr());
            crate::tw_world_set_main(world, main.as_ptr());
            let result = crate::tw_world_compile(world, crate::TWFormat::Html);
            let (data, len) = *(&result as *const _ as *const (*const u8, usize));
            let html = String::from_utf8_lossy(std::slice::from_raw_parts(data, len)).into_owned();
            crate::tw_result_free(result);
            crate::tw_world_free(world);
            let id: u64 = html.split("twimage:///image/png/").nth(1).expect(&html).split('"').next().unwrap().parse().unwrap();
            assert!(!html.contains("data:image"));
            // The world is gone, and with it the only output using the image.
            assert!(image(id).is_none());
        }
        std::fs::remove_dir_all(dir).ok();
    }

    /// A minimal PNG with stored (uncompressed) deflate blocks.
    fn png_bytes(w: u32, h: u32, raw: &[u8]) -> Vec<u8> {
        fn crc(data: &[u8]) -> u32 {
            let mut c = !0u32;
            for &b in data {
                c ^= b as u32;
                for _ in 0..8 { c = if c & 1 != 0 { 0xEDB88320 ^ (c >> 1) } else { c >> 1 }; }
            }
            !c
        }
        fn chunk(out: &mut Vec<u8>, kind: &[u8], data: &[u8]) {
            out.extend((data.len() as u32).to_be_bytes());
            let body: Vec<u8> = kind.iter().chain(data).copied().collect();
            out.extend(&body);
            out.extend(crc(&body).to_be_bytes());
        }
        let mut z = vec![0x78, 0x01];
        let blocks: Vec<&[u8]> = raw.chunks(65535).collect();
        for (i, block) in blocks.iter().enumerate() {
            z.push((i + 1 == blocks.len()) as u8);
            z.extend((block.len() as u16).to_le_bytes());
            z.extend((!(block.len() as u16)).to_le_bytes());
            z.extend(*block);
        }
        let (mut a, mut b) = (1u32, 0u32);
        for &x in raw { a = (a + x as u32) % 65521; b = (b + a) % 65521; }
        z.extend(((b << 16) | a).to_be_bytes());
        let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
        let mut ihdr = Vec::new();
        ihdr.extend(w.to_be_bytes());
        ihdr.extend(h.to_be_bytes());
        ihdr.extend([8, 2, 0, 0, 0]);
        chunk(&mut out, b"IHDR", &ihdr);
        chunk(&mut out, b"IDAT", &z);
        chunk(&mut out, b"IEND", &[]);
        out
    }
}
