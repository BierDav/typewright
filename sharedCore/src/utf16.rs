//! Offsets count UTF-16 units, like NSString, JavaScript strings and LSP.

/// A string indexed by UTF-16 unit.
pub(crate) struct Utf16(Vec<u16>);

impl Utf16 {
    pub fn new(text: &str) -> Self {
        Self(text.encode_utf16().collect())
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    /// The unit at `i` as a character; halves of surrogate pairs read as U+FFFD, which no check matches.
    pub fn at(&self, i: usize) -> char {
        char::from_u32(self.0[i] as u32).unwrap_or(char::REPLACEMENT_CHARACTER)
    }

    pub fn get(&self, i: usize) -> Option<char> {
        (i < self.len()).then(|| self.at(i))
    }

    pub fn units(&self) -> &[u16] {
        &self.0
    }

    pub fn slice(&self, start: usize, end: usize) -> String {
        String::from_utf16_lossy(&self.0[start..end])
    }

    /// `offset` clamped into the text.
    pub fn clamp(&self, offset: i32) -> usize {
        (offset.max(0) as usize).min(self.len())
    }

    pub fn starts_with(&self, at: usize, prefix: &str) -> bool {
        self.matches_at(at, prefix, |a, b| a == b)
    }

    /// Like `starts_with`, ignoring ASCII case.
    pub fn starts_with_ignoring_case(&self, at: usize, prefix: &str) -> bool {
        self.matches_at(at, prefix, eq_ignoring_case)
    }

    fn matches_at(&self, at: usize, prefix: &str, eq: impl Fn(u16, u16) -> bool) -> bool {
        let mut rest = self.0.get(at..).unwrap_or_default().iter();
        prefix.encode_utf16().all(|unit| rest.next().is_some_and(|&u| eq(u, unit)))
    }

    pub fn find(&self, needle: &str, from: usize) -> Option<usize> {
        (from..self.len()).find(|&i| self.starts_with(i, needle))
    }

    pub fn find_char(&self, c: char, from: usize) -> Option<usize> {
        (from..self.len()).find(|&i| self.at(i) == c)
    }
}

fn eq_ignoring_case(a: u16, b: u16) -> bool {
    a == b || (a < 128 && b < 128 && (a as u8).eq_ignore_ascii_case(&(b as u8)))
}

/// Splits on `\r\n`, `\n` and `\r`, keeping a trailing empty line.
pub(crate) fn lines(text: &str) -> impl Iterator<Item = &str> {
    text.split('\n').flat_map(|line| line.strip_suffix('\r').unwrap_or(line).split('\r'))
}

pub(crate) fn len(text: &str) -> i32 {
    text.encode_utf16().count() as i32
}
