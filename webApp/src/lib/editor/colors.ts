// Swatches before colour literals like `rgb("#ff4136")`, `rgb(255, 65, 54)`, `luma(40%)` or `red`, as in
// the Mac app's `ColorLiteral`; clicking one opens the colour picker and writes the colour back in its form.
import { RangeSetBuilder } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate, WidgetType } from "@codemirror/view";

type Format =
  | { type: "hex"; uppercase: boolean; alpha: boolean; short: boolean; hash: boolean }
  | { type: "components"; percent: boolean; alpha: boolean }
  | { type: "luma"; percent: boolean }
  | { type: "named" };

type Literal = { from: number; to: number; rgba: [number, number, number, number]; format: Format };

const NUMBER = String.raw`\s*(\d+(?:\.\d+)?%?)\s*`;
const HEX = /\brgb\(\s*"(#?)([0-9a-fA-F]{3,8})"\s*\)/g;
const COMPONENTS = new RegExp(String.raw`\brgb\(${NUMBER},${NUMBER},${NUMBER}(?:,${NUMBER})?\)`, "g");
const LUMA = new RegExp(String.raw`\bluma\(${NUMBER}\)`, "g");
// Only where a value is expected, so the words in prose stay plain.
const NAMED = /(?<=[:(,[]\s{0,3})\b(black|gray|silver|white|navy|blue|aqua|teal|eastern|purple|fuchsia|maroon|red|orange|yellow|olive|green|lime)\b(?![\w.(-])/g;

/** Typst's predefined colors. */
const PALETTE: Record<string, number> = {
  black: 0x000000, gray: 0xaaaaaa, silver: 0xdddddd, white: 0xffffff, navy: 0x001f3f, blue: 0x0074d9, aqua: 0x7fdbff,
  teal: 0x39cccc, eastern: 0x239dad, purple: 0xb10dc9, fuchsia: 0xf012be, maroon: 0x85144b, red: 0xff4136,
  orange: 0xff851b, yellow: 0xffdc00, olive: 0x3d9970, green: 0x2ecc40, lime: 0x01ff70,
};

function component(s: string): number | null {
  if (s.endsWith("%")) return Math.min(parseFloat(s) / 100, 1);
  // Typst only takes integers 0–255 for unscaled components.
  const v = Number(s);
  return Number.isInteger(v) && v <= 255 ? v / 255 : null;
}

export function findColors(text: string, offset = 0): Literal[] {
  const found: Literal[] = [];
  for (const m of text.matchAll(HEX)) {
    const digits = m[2];
    if (![3, 4, 6, 8].includes(digits.length)) continue;
    const full = digits.length <= 4 ? [...digits].map((c) => c + c).join("") : digits;
    const value = parseInt(full, 16);
    const alpha = full.length === 8;
    const rgb = alpha ? Math.floor(value / 256) : value;
    found.push({
      from: offset + m.index!,
      to: offset + m.index! + m[0].length,
      rgba: [((rgb >> 16) & 0xff) / 255, ((rgb >> 8) & 0xff) / 255, (rgb & 0xff) / 255, alpha ? (value & 0xff) / 255 : 1],
      format: { type: "hex", uppercase: /[A-F]/.test(digits), alpha, short: digits.length <= 4, hash: m[1] === "#" },
    });
  }
  for (const m of text.matchAll(COMPONENTS)) {
    const parts = m.slice(1, 5).filter((p): p is string => p !== undefined);
    const values = parts.map(component);
    if (values.some((v) => v === null)) continue;
    const [r, g, b, a] = values as number[];
    found.push({
      from: offset + m.index!,
      to: offset + m.index! + m[0].length,
      rgba: [r, g, b, a ?? 1],
      format: { type: "components", percent: parts[0].endsWith("%"), alpha: parts.length === 4 },
    });
  }
  for (const m of text.matchAll(LUMA)) {
    const v = component(m[1]);
    if (v === null) continue;
    found.push({ from: offset + m.index!, to: offset + m.index! + m[0].length, rgba: [v, v, v, 1], format: { type: "luma", percent: m[1].endsWith("%") } });
  }
  for (const m of text.matchAll(NAMED)) {
    const rgb = PALETTE[m[1]];
    found.push({
      from: offset + m.index!,
      to: offset + m.index! + m[0].length,
      rgba: [((rgb >> 16) & 0xff) / 255, ((rgb >> 8) & 0xff) / 255, (rgb & 0xff) / 255, 1],
      format: { type: "named" },
    });
  }
  return found.sort((a, b) => a.from - b.from);
}

/** Source for a colour: hex and `rgb(…)` keep their form, everything else becomes hex. */
export function colorSource(rgba: [number, number, number, number], format: Format): string {
  const byte = (v: number) => Math.round(Math.min(Math.max(v, 0), 1) * 255);
  const percent = (v: number) => {
    const p = Math.round(Math.min(Math.max(v, 0), 1) * 1000) / 10;
    return `${p}%`;
  };
  const [r, g, b, a] = rgba;
  const opaque = byte(a) === 255;
  if (format.type === "components") {
    const parts = [r, g, b].map((v) => (format.percent ? percent(v) : String(byte(v))));
    if (format.alpha || !opaque) parts.push(format.percent ? percent(a) : String(byte(a)));
    return `rgb(${parts.join(", ")})`;
  }
  const bytes = [r, g, b].map(byte);
  if ((format.type === "hex" && format.alpha) || !opaque) bytes.push(byte(a));
  // `#f80` stays short while every byte is a doubled digit.
  let hex =
    format.type === "hex" && format.short && bytes.every((v) => v % 17 === 0)
      ? bytes.map((v) => (v / 17).toString(16)).join("")
      : bytes.map((v) => v.toString(16).padStart(2, "0")).join("");
  if (format.type === "hex" && format.uppercase) hex = hex.toUpperCase();
  if (format.type === "hex" && !format.hash) return `rgb("${hex}")`;
  return `rgb("#${hex}")`;
}

function css([r, g, b, a]: [number, number, number, number]): string {
  return `rgba(${Math.round(r * 255)}, ${Math.round(g * 255)}, ${Math.round(b * 255)}, ${a})`;
}

class Swatch extends WidgetType {
  constructor(readonly literal: Literal) {
    super();
  }
  eq(other: Swatch) {
    return other.literal.from === this.literal.from && css(other.literal.rgba) === css(this.literal.rgba);
  }
  toDOM(view: EditorView) {
    const swatch = document.createElement("span");
    swatch.className = "tw-swatch";
    swatch.style.setProperty("--swatch", css(this.literal.rgba));
    swatch.title = "Change colour";
    swatch.addEventListener("mousedown", (event) => {
      event.preventDefault();
      pick(view, this.literal);
    });
    return swatch;
  }
  ignoreEvent() {
    return true;
  }
}

/** The browser's colour picker; its edits apply live, so the preview follows the drag. */
function pick(view: EditorView, literal: Literal) {
  const input = document.createElement("input");
  input.type = "color";
  const [r, g, b] = literal.rgba.map((v) => Math.round(v * 255));
  input.value = `#${[r, g, b].map((v) => v.toString(16).padStart(2, "0")).join("")}`;
  Object.assign(input.style, { position: "fixed", opacity: "0", pointerEvents: "none" });
  const coords = view.coordsAtPos(literal.from);
  if (coords) Object.assign(input.style, { left: `${coords.left}px`, top: `${coords.bottom}px` });
  document.body.append(input);
  let range = { from: literal.from, to: literal.to };
  let format = literal.format;
  input.addEventListener("input", () => {
    const hex = parseInt(input.value.slice(1), 16);
    const rgba: [number, number, number, number] = [((hex >> 16) & 0xff) / 255, ((hex >> 8) & 0xff) / 255, (hex & 0xff) / 255, literal.rgba[3]];
    const source = colorSource(rgba, format);
    view.dispatch({ changes: { from: range.from, to: range.to, insert: source }, userEvent: "input.color" });
    range = { from: range.from, to: range.from + source.length };
    format = findColors(source)[0]?.format ?? format;
  });
  input.addEventListener("change", () => input.remove());
  input.addEventListener("blur", () => input.remove());
  input.showPicker?.() ?? input.click();
}

function decorations(view: EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  for (const { from, to } of view.visibleRanges) {
    for (const literal of findColors(view.state.sliceDoc(from, to), from)) {
      builder.add(literal.from, literal.from, Decoration.widget({ widget: new Swatch(literal), side: -1 }));
    }
  }
  return builder.finish();
}

export const colorSwatches = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    constructor(view: EditorView) {
      this.decorations = decorations(view);
    }
    update(update: ViewUpdate) {
      if (update.docChanged || update.viewportChanged) this.decorations = decorations(update.view);
    }
  },
  { decorations: (v) => v.decorations },
);
