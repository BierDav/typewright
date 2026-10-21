//! `typewright://join/<payload>` links; the payload is base64url of a small binary layout. Web links
//! (`<web app>/join#<payload>`) carry the same payload and join in the browser.
use base64::Engine;
use base64::engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig};

/// Everything another account needs to sync a space: its replica's namespace secret (hex), the space's
/// id and name, and endpoint ids (hex) of devices syncing it, to dial before the space's record resolves.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
#[cfg_attr(target_arch = "wasm32", derive(serde::Serialize, serde::Deserialize, tsify::Tsify))]
pub struct SpaceInvite {
    pub id: String,
    pub name: String,
    pub secret: String,
    pub hints: Vec<String>,
}

pub const SCHEME: &str = "typewright";
/// Where the web app is hosted (GitHub Pages).
pub const WEB_APP: &str = "https://bierdav.github.io/typewright/";
const PREFIX: &str = "typewright://join/";
const WEB_PATH: &str = "join#";
const VERSION: u8 = 1;
/// Keeps links short enough for chat apps.
pub const MAX_HINTS: usize = 3;
const MAX_NAME_BYTES: usize = 120;
const BASE64: GeneralPurpose = GeneralPurpose::new(
    &base64::alphabet::URL_SAFE,
    GeneralPurposeConfig::new().with_encode_padding(false).with_decode_padding_mode(DecodePaddingMode::Indifferent),
);

#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn invite_scheme() -> String {
    SCHEME.to_string()
}

/// Layout: version, 32-byte secret, id and name (each length-prefixed UTF-8), then 32-byte hints.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn invite_link(invite: SpaceInvite) -> Option<String> {
    let secret = from_hex(&invite.secret).filter(|s| s.len() == 32)?;
    if !is_valid_id(&invite.id) {
        return None;
    }
    let name = truncate(folder_name(&invite.name), MAX_NAME_BYTES);
    let mut bytes = vec![VERSION];
    bytes.extend(secret);
    bytes.push(invite.id.len() as u8);
    bytes.extend(invite.id.as_bytes());
    bytes.push(name.len() as u8);
    bytes.extend(name.as_bytes());
    for hint in invite.hints.iter().filter_map(|h| from_hex(h).filter(|h| h.len() == 32)).take(MAX_HINTS) {
        bytes.extend(hint);
    }
    Some(format!("{PREFIX}{}", BASE64.encode(bytes)))
}

/// The web app's form of `link`, below `web_app` (ending in `/`, the hosted app by default).
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export(default(web_app = None)))]
pub fn web_invite_link(link: &str, web_app: Option<String>) -> Option<String> {
    let payload = link.strip_prefix(PREFIX)?;
    Some(format!("{}{WEB_PATH}{payload}", web_app.as_deref().unwrap_or(WEB_APP)))
}

/// None for anything that isn't a well-formed invite link, app or web.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn parse_invite(link: &str) -> Option<SpaceInvite> {
    let text = link.trim();
    let payload = if let Some(rest) = text.strip_prefix(PREFIX) {
        rest.trim_end_matches('/')
    } else if text.starts_with("https://") || text.starts_with("http://") {
        let marker = format!("/{WEB_PATH}");
        let at = text.find(&marker)?;
        Some(&text[at + marker.len()..]).filter(|p| !p.is_empty())?
    } else {
        return None;
    };
    let bytes = BASE64.decode(payload).ok()?;
    if bytes.len() < 35 || bytes[0] != VERSION {
        return None;
    }
    let mut at = 33;
    let mut field = || {
        let length = *bytes.get(at)? as usize;
        let text = String::from_utf8_lossy(bytes.get(at + 1..at + 1 + length)?).into_owned();
        at += 1 + length;
        Some(text)
    };
    let id = field().filter(|id| is_valid_id(id))?;
    let name = folder_name(&field()?);
    if (bytes.len() - at) % 32 != 0 {
        return None;
    }
    let hints = bytes[at..].chunks(32).map(hex).collect();
    Some(SpaceInvite { id, name, secret: hex(&bytes[1..33]), hints })
}

/// Ids name keys in replicas, so they stay plain.
pub fn is_valid_id(id: &str) -> bool {
    (1..=64).contains(&id.len()) && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// The name works as a folder name: no separators, never empty or hidden.
pub fn folder_name(name: &str) -> String {
    let clean: String = name.chars().map(|c| if c == '/' || c == ':' || (c as u32) < 0x20 { '-' } else { c }).collect();
    let clean = clean.trim().trim_start_matches('.');
    if clean.is_empty() { "Shared Space".to_string() } else { clean.to_string() }
}

/// Drops whole characters, so no UTF-8 sequence is cut.
fn truncate(mut text: String, max_bytes: usize) -> String {
    while text.len() > max_bytes {
        text.pop();
    }
    text
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn from_hex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) || !text.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(&text[i..i + 2], 16).ok()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn secret() -> String {
        (0..32).map(|i| format!("{:02x}", i * 7 % 256)).collect()
    }

    fn device() -> String {
        "ab".repeat(32)
    }

    fn invite(id: &str, name: &str, secret: String, hints: Vec<String>) -> SpaceInvite {
        SpaceInvite { id: id.into(), name: name.into(), secret, hints }
    }

    #[test]
    fn round_trips() {
        let invite = invite("1b4e28ba-2fa1-11d2-883f-0016d3cca427", "Thesis ✍️", secret(), vec![device(), "cd".repeat(32)]);
        let link = invite_link(invite.clone()).unwrap();
        assert!(link.starts_with("typewright://join/"));
        assert!(!link["typewright://join/".len()..].contains(['+', '/', '=']));
        assert_eq!(Some(invite.clone()), parse_invite(&link));
        assert_eq!(Some(invite), parse_invite(&format!("  {link}/ ")));
    }

    #[test]
    fn web_links_carry_the_same_payload() {
        let invite = invite("space-1", "Thesis", secret(), vec![device()]);
        let link = invite_link(invite.clone()).unwrap();
        let web = web_invite_link(&link, None).unwrap();
        assert_eq!(format!("{WEB_APP}join#{}", &link["typewright://join/".len()..]), web);
        assert_eq!(Some(invite.clone()), parse_invite(&web));
        assert_eq!(Some(invite), parse_invite(&web_invite_link(&link, Some("http://localhost:5173/".into())).unwrap()));
        assert_eq!(None, web_invite_link("https://example.com", None));
    }

    #[test]
    fn cleans_names_and_drops_bad_hints() {
        let hints = vec!["nope".into(), device(), device(), device(), device()];
        let link = invite_link(invite("x", "../a/b:c", secret().to_uppercase(), hints)).unwrap();
        let parsed = parse_invite(&link).unwrap();
        assert_eq!("-a-b-c", parsed.name);
        assert_eq!(secret(), parsed.secret);
        assert_eq!(MAX_HINTS, parsed.hints.len());
        assert_eq!("Shared Space", folder_name(" .. "));
        let long = parse_invite(&invite_link(invite("x", &"😀".repeat(100), secret(), vec![])).unwrap()).unwrap();
        assert_eq!("😀".repeat(30), long.name);
    }

    #[test]
    fn rejects_malformed_links() {
        assert_eq!(None, invite_link(invite("x", "a", "00".into(), vec![])));
        assert_eq!(None, invite_link(invite("a/b", "a", secret(), vec![])));
        assert_eq!(None, parse_invite("https://join/abc"));
        assert_eq!(None, parse_invite("typewright://join/"));
        assert_eq!(None, parse_invite("typewright://join/!!!"));
        let link = invite_link(invite("x", "a", secret(), vec![device()])).unwrap();
        // Cut hints and a wrong version don't parse.
        assert_eq!(None, parse_invite(&link[..link.len() - 4]));
        assert_eq!(None, parse_invite(&format!("typewright://join/B{}", &link["typewright://join/".len() + 1..])));
    }
}
