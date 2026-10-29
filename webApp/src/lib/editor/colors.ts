// Swatches before colour literals like `rgb("#ff4136")`, `rgb(255, 65, 54)`, `luma(40%)` or `red`, as in
// the Mac app's `ColorLiteral`; clicking one opens Monaco's colour picker, which writes the colour back in its form.
import { monaco, range } from "./monaco";

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

/** Monaco's colour decorators for typst, with its picker; presentations keep the literal's form. */
export function registerColors(): monaco.IDisposable {
  return monaco.languages.registerColorProvider("typst", {
    provideDocumentColors(model) {
      return findColors(model.getValue()).map((l) => ({
        range: range(model, l.from, l.to),
        color: { red: l.rgba[0], green: l.rgba[1], blue: l.rgba[2], alpha: l.rgba[3] },
      }));
    },
    provideColorPresentations(model, info) {
      const literal = findColors(model.getValueInRange(info.range))[0];
      const { red, green, blue, alpha } = info.color;
      return [{ label: colorSource([red, green, blue, alpha], literal?.format ?? { type: "named" }) }];
    },
  });
}
