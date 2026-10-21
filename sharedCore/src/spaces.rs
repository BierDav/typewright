//! The user's spaces in their chosen order, as stored paths. Storage and file system checks stay with
//! the platform; `visible` is the stored list resolved to existing space folders.

/// Appends a new space; known ones keep their place.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn space_order_add(mut stored: Vec<String>, path: String) -> Vec<String> {
    if !stored.contains(&path) {
        stored.push(path);
    }
    stored
}

/// Moves a visible space to `index`; missing folders keep their entries for when they return.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn space_order_move(stored: Vec<String>, visible: Vec<String>, path: &str, index: i32) -> Vec<String> {
    let mut order = visible;
    let Some(from) = order.iter().position(|p| p == path) else { return stored };
    let item = order.remove(from);
    order.insert((index.max(0) as usize).min(order.len()), item);
    let rest: Vec<String> = stored.into_iter().filter(|p| !order.contains(p)).collect();
    order.extend(rest);
    order
}

/// Swaps a renamed space in place, keeping its position.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn space_order_replace(stored: Vec<String>, old: &str, new: &str) -> Vec<String> {
    stored.into_iter().map(|p| if p == old { new.to_string() } else { p }).collect()
}

/// Lower is better: prefix, word start, substring, then scattered letters; None if no match.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn fuzzy_score(query: &str, text: &str) -> Option<i32> {
    if text.starts_with(query) {
        return Some(0);
    }
    if text.contains(&format!(" {query}")) || text.contains(&format!("/{query}")) {
        return Some(1);
    }
    if text.contains(query) {
        return Some(2);
    }
    let mut rest = text.chars();
    for c in query.chars() {
        rest.find(|&t| t == c)?;
    }
    Some(4)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn list(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn keeps_order_and_hidden_entries() {
        let stored = list(&["/a", "/gone", "/b", "/c"]);
        let visible = list(&["/a", "/b", "/c"]);
        assert_eq!(stored, space_order_add(stored.clone(), "/b".into()));
        assert_eq!(list(&["/a", "/gone", "/b", "/c", "/d"]), space_order_add(stored.clone(), "/d".into()));
        assert_eq!(list(&["/b", "/c", "/a", "/gone"]), space_order_move(stored.clone(), visible.clone(), "/a", 9));
        assert_eq!(list(&["/c", "/a", "/b", "/gone"]), space_order_move(stored.clone(), visible.clone(), "/c", -1));
        assert_eq!(stored, space_order_move(stored.clone(), visible, "/x", 0));
        assert_eq!(list(&["/a", "/gone", "/z", "/c"]), space_order_replace(stored, "/b", "/z"));
    }

    #[test]
    fn scores_matches() {
        assert_eq!(Some(0), fuzzy_score("ma", "main.typ"));
        assert_eq!(Some(1), fuzzy_score("ty", "new typ"));
        assert_eq!(Some(2), fuzzy_score("in", "main.typ"));
        assert_eq!(Some(4), fuzzy_score("mt", "main.typ"));
        assert_eq!(None, fuzzy_score("zz", "main.typ"));
    }
}
