#!/usr/bin/env bash
# Makes the desktop app's icons from the web app's logo (macOS: sips and iconutil), so packaging converts nothing.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
src="$root/webApp/public/logo.png"
out="$root/desktopApp/build"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out/icons" "$tmp/icon.iconset"

# Linux: one PNG per size, named the way electron-builder looks them up.
for size in 16 24 32 48 64 128 256 512; do
  sips -z $size $size "$src" --out "$out/icons/${size}x${size}.png" >/dev/null
done

# macOS
for size in 16 32 128 256 512; do
  sips -z $size $size "$src" --out "$tmp/icon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  [ $double -le 512 ] && sips -z $double $double "$src" --out "$tmp/icon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$tmp/icon.iconset" -o "$out/icon.icns"

# Windows: an .ico holding PNGs, which Windows Vista and later read.
bun -e '
const [dir, target] = process.argv.slice(1);
const sizes = [16, 24, 32, 48, 64, 128, 256];
const images = await Promise.all(sizes.map((s) => Bun.file(`${dir}/${s}x${s}.png`).bytes()));
const header = new DataView(new ArrayBuffer(6 + 16 * sizes.length));
header.setUint16(2, 1, true);
header.setUint16(4, sizes.length, true);
let offset = header.byteLength;
sizes.forEach((s, i) => {
  const at = 6 + 16 * i;
  header.setUint8(at, s % 256);
  header.setUint8(at + 1, s % 256);
  header.setUint16(at + 4, 1, true);
  header.setUint16(at + 6, 32, true);
  header.setUint32(at + 8, images[i].length, true);
  header.setUint32(at + 12, offset, true);
  offset += images[i].length;
});
await Bun.write(target, new Blob([header.buffer, ...images]));
' "$out/icons" "$out/icon.ico"
