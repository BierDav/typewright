use std::cmp::Ordering;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
pub struct ReleaseAsset {
    pub name: String,
    pub url: String,
}

/// The parts of a GitHub release that matter for picking compilers.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
pub struct GitHubRelease {
    pub tag: String,
    pub prerelease: bool,
    pub assets: Vec<ReleaseAsset>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
pub struct TypstRelease {
    pub version: String,
    pub asset_url: String,
}

/// Newest patch of each minor version since 0.11 that ships `asset_name`, newest first.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn pick_typst_releases(all: Vec<GitHubRelease>, asset_name: &str) -> Vec<TypstRelease> {
    let mut by_minor: Vec<(String, TypstRelease)> = Vec::new();
    for release in all {
        if release.prerelease {
            continue;
        }
        let version = release.tag.trim_matches('v');
        let parts: Vec<i32> = version.split('.').filter_map(|p| p.parse().ok()).collect();
        if parts.len() != 3 || (parts[0] == 0 && parts[1] < 11) {
            continue;
        }
        let Some(asset) = release.assets.iter().find(|a| a.name == asset_name) else { continue };
        let key = format!("{}.{}", parts[0], parts[1]);
        let picked = TypstRelease { version: version.to_string(), asset_url: asset.url.clone() };
        match by_minor.iter_mut().find(|(k, _)| *k == key) {
            Some((_, existing)) if is_newer_version(&existing.version, version) => {}
            Some((_, existing)) => *existing = picked,
            None => by_minor.push((key, picked)),
        }
    }
    let mut releases: Vec<TypstRelease> = by_minor.into_iter().map(|(_, r)| r).collect();
    releases.sort_by(|a, b| compare(&b.version, &a.version));
    releases
}

/// True if `a` is newer than `b`.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn is_newer_version(a: &str, b: &str) -> bool {
    compare(a, b) == Ordering::Greater
}

/// Orders digit runs by value and everything else by character, like Finder sorts names.
fn compare(a: &str, b: &str) -> Ordering {
    let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    let (mut i, mut j) = (0, 0);
    while i < a.len() && j < b.len() {
        if a[i].is_numeric() && b[j].is_numeric() {
            let (si, sj) = (i, j);
            while i < a.len() && a[i].is_numeric() {
                i += 1;
            }
            while j < b.len() && b[j].is_numeric() {
                j += 1;
            }
            let x: String = a[si..i].iter().collect();
            let y: String = b[sj..j].iter().collect();
            let (x, y) = (x.trim_start_matches('0'), y.trim_start_matches('0'));
            let order = x.chars().count().cmp(&y.chars().count()).then_with(|| x.cmp(y));
            if order != Ordering::Equal {
                return order;
            }
        } else {
            if a[i] != b[j] {
                return a[i].cmp(&b[j]);
            }
            i += 1;
            j += 1;
        }
    }
    (a.len() - i).cmp(&(b.len() - j))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_newest_patch_per_minor() {
        let asset = "typst-aarch64-apple-darwin.tar.xz";
        let r = |tag: &str, prerelease: bool| GitHubRelease {
            tag: tag.into(),
            prerelease,
            assets: vec![ReleaseAsset { name: asset.into(), url: format!("https://x/{tag}") }],
        };
        let picked = pick_typst_releases(
            vec![
                r("v0.15.0-rc.1", true),
                r("v0.15.1", false),
                r("v0.15.0", false),
                r("v0.14.2", false),
                r("v0.14.10", false),
                r("v0.10.0", false),
            ],
            asset,
        );
        assert_eq!(vec!["0.15.1", "0.14.10"], picked.iter().map(|r| r.version.as_str()).collect::<Vec<_>>());
        assert_eq!("https://x/v0.15.1", picked[0].asset_url);
    }

    #[test]
    fn compares_numerically() {
        assert!(is_newer_version("0.14.10", "0.14.2"));
        assert!(is_newer_version("1.0.0", "0.99.99"));
        assert!(!is_newer_version("0.13.1", "0.13.1"));
        assert!(is_newer_version("0.13.1-rc.2", "0.13.1-rc.1"));
        assert!(is_newer_version("0.13.1.1", "0.13.1"));
    }
}
