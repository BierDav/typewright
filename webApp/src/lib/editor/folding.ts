// Folding for typst, whose stream language has no syntax tree: brackets spanning lines and heading sections.
import { foldService, matchBrackets } from "@codemirror/language";
import type { EditorState } from "@codemirror/state";

const HEADING = /^\s*(=+)\s/;

/** A heading folds up to the next heading of the same or a higher level. */
function headingRange(state: EditorState, lineStart: number, lineEnd: number): { from: number; to: number } | null {
  const level = HEADING.exec(state.sliceDoc(lineStart, lineEnd))?.[1].length;
  if (!level) return null;
  const first = state.doc.lineAt(lineStart).number;
  let last = first;
  let fence = false;
  for (let n = first + 1; n <= state.doc.lines; n++) {
    const text = state.doc.line(n).text;
    if (/^\s*```/.test(text)) fence = !fence;
    const other = fence ? undefined : HEADING.exec(text)?.[1].length;
    if (other && other <= level) break;
    if (text.trim()) last = n;
  }
  return last > first ? { from: lineEnd, to: state.doc.line(last).to } : null;
}

/** The first bracket opened on the line and closed on a later one. */
function bracketRange(state: EditorState, lineStart: number, lineEnd: number): { from: number; to: number } | null {
  const text = state.sliceDoc(lineStart, lineEnd);
  // Comments on the line don't open anything.
  const end = text.indexOf("//") >= 0 ? text.indexOf("//") : text.length;
  for (let i = 0; i < end; i++) {
    if (!"([{".includes(text[i])) continue;
    const match = matchBrackets(state, lineStart + i, 1);
    if (!match?.matched || !match.end) continue;
    if (match.end.from > lineEnd) {
      // Folds up to the line holding the closing bracket, so that line stays visible.
      const close = state.doc.lineAt(match.end.from);
      const to = close.text.slice(0, match.end.from - close.from).trim() ? match.end.from : close.from - 1;
      return to > lineStart + i + 1 ? { from: lineStart + i + 1, to } : null;
    }
    // Closed on this line: skip past it.
    i = match.end.to - lineStart - 1;
  }
  return null;
}

export const typstFolding = foldService.of((state, lineStart, lineEnd) => headingRange(state, lineStart, lineEnd) ?? bracketRange(state, lineStart, lineEnd));
