// Folding for typst, which has no syntax tree here: brackets spanning lines and heading sections.
import { monaco } from "./monaco";

const HEADING = /^\s*(=+)\s/;
const PAIRS: Record<string, string> = { ")": "(", "]": "[", "}": "{" };

/** A heading folds up to the next heading of the same or a higher level. */
function headingRange(lines: string[], first: number): number | null {
  const level = HEADING.exec(lines[first])?.[1].length;
  if (!level) return null;
  let last = first;
  let fence = false;
  for (let n = first + 1; n < lines.length; n++) {
    const text = lines[n];
    if (/^\s*```/.test(text)) fence = !fence;
    const other = fence ? undefined : HEADING.exec(text)?.[1].length;
    if (other && other <= level) break;
    if (text.trim()) last = n;
  }
  return last > first ? last : null;
}

/** Each bracket's matching one, as (line, column) of the closer by the opener's offset. */
function matches(text: string): Map<number, { line: number; column: number }> {
  const found = new Map<number, { line: number; column: number }>();
  const stack: { char: string; at: number }[] = [];
  let line = 0;
  let lineStart = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === "\n") {
      line++;
      lineStart = i + 1;
    } else if (c === "(" || c === "[" || c === "{") {
      stack.push({ char: c, at: i });
    } else if (PAIRS[c] && stack.at(-1)?.char === PAIRS[c]) {
      found.set(stack.pop()!.at, { line, column: i - lineStart });
    }
  }
  return found;
}

export function registerFolding(): monaco.IDisposable {
  return monaco.languages.registerFoldingRangeProvider("typst", {
    provideFoldingRanges(model) {
      const lines = model.getLinesContent();
      const closers = matches(model.getValue(monaco.editor.EndOfLinePreference.LF));
      const ranges: monaco.languages.FoldingRange[] = [];
      let offset = 0;
      for (let n = 0; n < lines.length; offset += lines[n].length + 1, n++) {
        const heading = headingRange(lines, n);
        if (heading !== null) {
          ranges.push({ start: n + 1, end: heading + 1 });
          continue;
        }
        // The first bracket opened on the line and closed on a later one; comments on the line don't open anything.
        const text = lines[n];
        const end = text.indexOf("//") >= 0 ? text.indexOf("//") : text.length;
        for (let i = 0; i < end; i++) {
          const close = "([{".includes(text[i]) ? closers.get(offset + i) : undefined;
          if (!close || close.line === n) continue;
          // A closing line that starts with the bracket stays visible.
          const last = lines[close.line].slice(0, close.column).trim() ? close.line : close.line - 1;
          if (last > n) ranges.push({ start: n + 1, end: last + 1 });
          break;
        }
      }
      return ranges;
    },
  });
}
