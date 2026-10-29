export type SelectionBox = { x: number; y: number; width: number; height: number };
type Point = [number, number];
const key = ([x, y]: Point) => `${x},${y}`;

/** Union before rounding keeps adjacent rows connected, including inward corners. */
export function selectionShape(boxes: SelectionBox[]): string {
  boxes = boxes.filter((b) => b.width > 0 && b.height > 0);
  const xs = [...new Set(boxes.flatMap((b) => [b.x, b.x + b.width]))].sort((a, b) => a - b);
  const ys = [...new Set(boxes.flatMap((b) => [b.y, b.y + b.height]))].sort((a, b) => a - b);
  const edges = new Map<string, { a: Point; b: Point }>();
  function edge(a: Point, b: Point) {
    const reverse = `${key(b)}:${key(a)}`;
    if (!edges.delete(reverse)) edges.set(`${key(a)}:${key(b)}`, { a, b });
  }
  for (let y = 0; y < ys.length - 1; y++) for (let x = 0; x < xs.length - 1; x++) {
    const cx = (xs[x] + xs[x + 1]) / 2, cy = (ys[y] + ys[y + 1]) / 2;
    if (!boxes.some((b) => cx >= b.x && cx < b.x + b.width && cy >= b.y && cy < b.y + b.height)) continue;
    const a: Point = [xs[x], ys[y]], b: Point = [xs[x + 1], ys[y]], c: Point = [xs[x + 1], ys[y + 1]], d: Point = [xs[x], ys[y + 1]];
    edge(a, b); edge(b, c); edge(c, d); edge(d, a);
  }
  const outgoing = new Map<string, string[]>();
  for (const [id, { a }] of edges) outgoing.set(key(a), [...(outgoing.get(key(a)) ?? []), id]);
  let path = "";
  while (edges.size) {
    const first = edges.values().next().value!;
    const points: Point[] = [];
    let current = first;
    do {
      points.push(current.a);
      edges.delete(`${key(current.a)}:${key(current.b)}`);
      const next = outgoing.get(key(current.b))?.find((id) => edges.has(id));
      if (!next || key(current.b) === key(first.a)) break;
      current = edges.get(next)!;
    } while (points.length <= outgoing.size);
    const corners = points.filter((p, i) => {
      const a = points[(i + points.length - 1) % points.length], b = points[(i + 1) % points.length];
      return (p[0] - a[0]) * (b[1] - p[1]) !== (p[1] - a[1]) * (b[0] - p[0]);
    });
    corners.forEach((p, i) => {
      const a = corners[(i + corners.length - 1) % corners.length], b = corners[(i + 1) % corners.length];
      const before = Math.hypot(a[0] - p[0], a[1] - p[1]), after = Math.hypot(b[0] - p[0], b[1] - p[1]);
      const r = Math.min(5, before / 2, after / 2);
      const entry = [p[0] + (a[0] - p[0]) * r / before, p[1] + (a[1] - p[1]) * r / before];
      const exit = [p[0] + (b[0] - p[0]) * r / after, p[1] + (b[1] - p[1]) * r / after];
      path += `${i ? "L" : "M"}${entry}Q${p} ${exit}`;
    });
    path += "Z";
  }
  return path;
}
