use crate::text::TextRange;
use crate::utf16::Utf16;

const LOOKBACK: usize = 4000;

/// A named argument of a call, like `unit` in `solve(x, unit: "min")`, and where its name stands.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
pub struct NamedArgument {
    pub name: String,
    pub range: TextRange,
}

/// The named argument whose name or value `offset` is in; None for positional arguments and outside calls.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn named_argument(text: &str, offset: i32) -> Option<NamedArgument> {
    let t = Utf16::new(text);
    let at = t.clamp(offset);
    // On the name itself, like hovering `unit`.
    let (mut start, mut end) = (at, at);
    while start > 0 && is_name(t.at(start - 1)) {
        start -= 1;
    }
    while end < t.len() && is_name(t.at(end)) {
        end += 1;
    }
    if start < end && is_key(&t, start, end) {
        return Some(argument(&t, start, end));
    }
    // In the value: back to the comma or parenthesis that starts this argument.
    let escaped = |i: usize| i > 0 && t.at(i - 1) == '\\';
    // Inside a string when the line so far has an odd number of quotes; the scan flips at each one.
    let mut quoted = false;
    for j in (0..at).rev() {
        if t.at(j) == '\n' {
            break;
        }
        if t.at(j) == '"' && !escaped(j) {
            quoted = !quoted;
        }
    }
    let mut depth = 0;
    for i in (at.saturating_sub(LOOKBACK)..at).rev() {
        let c = t.at(i);
        if c == '"' && !escaped(i) {
            quoted = !quoted;
        }
        if quoted {
            continue;
        }
        match c {
            ')' | ']' | '}' => depth += 1,
            '(' | '[' | '{' if depth == 0 => return if c == '(' { key_after(&t, i + 1) } else { None },
            '(' | '[' | '{' => depth -= 1,
            ',' if depth == 0 => return key_after(&t, i + 1),
            _ => {}
        }
    }
    None
}

/// The name of the function whose call's parentheses hold `offset`, like `grid` in `grid(columns: 2)`.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn callee_name(text: &str, offset: i32) -> Option<TextRange> {
    let t = Utf16::new(text);
    let at = t.clamp(offset);
    let escaped = |i: usize| i > 0 && t.at(i - 1) == '\\';
    let mut quoted = (0..at).rev().take_while(|&j| t.at(j) != '\n').filter(|&j| t.at(j) == '"' && !escaped(j)).count() % 2 == 1;
    let mut depth = 0;
    for i in (at.saturating_sub(LOOKBACK)..at).rev() {
        let c = t.at(i);
        if c == '"' && !escaped(i) {
            quoted = !quoted;
        }
        if quoted {
            continue;
        }
        match c {
            ')' | ']' | '}' => depth += 1,
            '(' if depth == 0 => {
                let mut start = i;
                while start > 0 && is_name(t.at(start - 1)) {
                    start -= 1;
                }
                return (start < i).then(|| TextRange { location: start as i32, length: (i - start) as i32 });
            }
            '[' | '{' if depth == 0 => return None,
            '(' | '[' | '{' => depth -= 1,
            _ => {}
        }
    }
    None
}

/// The type a signature like `solve(approx: auto | bool, unit: str)` gives the parameter `name`.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn parameter_type(signature: &str, name: &str) -> Option<String> {
    let s = Utf16::new(signature);
    let needle = format!("{name}:");
    let mut from = 0;
    loop {
        let index = s.find(&needle, from)?;
        from = index + 1;
        if index > 0 && is_name(s.at(index - 1)) {
            continue;
        }
        let mut depth = 0;
        let start = index + crate::utf16::len(&needle) as usize;
        let mut i = start;
        while i < s.len() {
            let c = s.at(i);
            if matches!(c, '(' | '[' | '{') {
                depth += 1;
            }
            if matches!(c, ')' | ']' | '}') {
                if depth == 0 {
                    break;
                }
                depth -= 1;
            }
            if c == ',' && depth == 0 {
                break;
            }
            i += 1;
        }
        let ty = s.slice(start, i);
        let ty = ty.trim();
        return (!ty.is_empty()).then(|| ty.to_string());
    }
}

/// The argument's name if the argument starting at `from` is named.
fn key_after(t: &Utf16, from: usize) -> Option<NamedArgument> {
    let mut start = from;
    while start < t.len() && t.at(start).is_whitespace() {
        start += 1;
    }
    let mut end = start;
    while end < t.len() && is_name(t.at(end)) {
        end += 1;
    }
    (start < end && is_key(t, start, end)).then(|| argument(t, start, end))
}

/// A name followed by a colon and preceded by the call's parenthesis or a comma.
fn is_key(t: &Utf16, start: usize, end: usize) -> bool {
    if !t.at(start).is_alphabetic() && t.at(start) != '_' {
        return false;
    }
    let mut after = end;
    while after < t.len() && matches!(t.at(after), ' ' | '\t') {
        after += 1;
    }
    if t.get(after) != Some(':') {
        return false;
    }
    (0..start).rev().map(|i| t.at(i)).find(|c| !c.is_whitespace()).is_some_and(|c| c == '(' || c == ',')
}

fn argument(t: &Utf16, start: usize, end: usize) -> NamedArgument {
    NamedArgument { name: t.slice(start, end), range: TextRange { location: start as i32, length: (end - start) as i32 } }
}

fn is_name(c: char) -> bool {
    c.is_alphanumeric() || c == '_' || c == '-'
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_named_arguments() {
        let text = "#solve($ t = \"@Q\" / I $, unit: \"min\", digits: f(1, 2))";
        let at = |needle: &str| text.find(needle).unwrap() as i32;
        assert_eq!("unit", named_argument(text, at("unit") + 2).unwrap().name);
        assert_eq!(TextRange { location: at("unit"), length: 4 }, named_argument(text, at("min")).unwrap().range);
        assert_eq!("digits", named_argument(text, at("f(")).unwrap().name);
        assert_eq!(None, named_argument(text, at("2)")), "an inner call's positional argument");
        assert_eq!(None, named_argument(text, at("@Q")), "positional");
        assert_eq!(None, named_argument("#let unit: x", 6));
        assert_eq!(None, named_argument("Note: (unit: x)", 0));
    }

    #[test]
    fn finds_callees() {
        let text = "#grid(columns: (1fr, 2fr), \"(\", fill: red)[a]";
        let at = |needle: &str| text.find(needle).unwrap() as i32;
        assert_eq!(Some(TextRange { location: 1, length: 4 }), callee_name(text, at("columns")));
        assert_eq!(Some(TextRange { location: 1, length: 4 }), callee_name(text, at("fill")));
        assert_eq!(None, callee_name(text, at("1fr")), "inside an array");
        assert_eq!(None, callee_name(text, at("a]")));
    }

    #[test]
    fn reads_parameter_types() {
        let signature = "solve(approx: auto | bool, config: dictionary, unit: auto | str, sci: array | (a, b)) -> content";
        assert_eq!(Some("auto | str".into()), parameter_type(signature, "unit"));
        assert_eq!(Some("array | (a, b)".into()), parameter_type(signature, "sci"));
        assert_eq!(None, parameter_type(signature, "fig"));
    }
}
