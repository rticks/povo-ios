// Dependency-free, original SIM-card icon (not povo's logo).
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const size = 1024;
const raw = Buffer.alloc((size * 3 + 1) * size);
const bg = [242, 213, 68], ink = [37, 37, 31], chip = [255, 245, 180];
function polygon(x, y, points) {
  let inside = false;
  for (let i = 0, j = points.length - 1; i < points.length; j = i++) {
    const [xi, yi] = points[i], [xj, yj] = points[j];
    if ((yi > y) !== (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}
for (let y = 0; y < size; y++) {
  const start = y * (size * 3 + 1); raw[start] = 0;
  for (let x = 0; x < size; x++) {
    let color = bg;
    if (polygon(x, y, [[300, 202], [582, 202], [744, 364], [744, 786], [300, 786], [280, 766], [280, 222]])) color = ink;
    if (x >= 354 && x < 670 && y >= 448 && y < 676) {
      color = chip;
      if ((x >= 452 && x < 466) || (x >= 558 && x < 572) || (y >= 518 && y < 532) || (y >= 596 && y < 610)) color = ink;
    }
    const at = start + 1 + x * 3;
    raw[at] = color[0]; raw[at + 1] = color[1]; raw[at + 2] = color[2];
  }
}
function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) { crc ^= byte; for (let k = 0; k < 8; k++) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1)); }
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const name = Buffer.from(type), len = Buffer.alloc(4), crc = Buffer.alloc(4);
  len.writeUInt32BE(data.length); crc.writeUInt32BE(crc32(Buffer.concat([name, data])));
  return Buffer.concat([len, name, data, crc]);
}
const header = Buffer.alloc(13); header.writeUInt32BE(size, 0); header.writeUInt32BE(size, 4); header[8] = 8; header[9] = 2;
const png = Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', header), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
const base = path.resolve(__dirname, '../App/Resources/Assets.xcassets');
fs.writeFileSync(path.join(base, 'AppIcon.appiconset/icon-1024.png'), png);
fs.writeFileSync(path.join(base, 'AppIcon.appiconset/Contents.json'), JSON.stringify({images:[{filename:'icon-1024.png',idiom:'universal',platform:'ios',size:'1024x1024'}],info:{author:'xcode',version:1}}, null, 2) + '\n');
fs.writeFileSync(path.join(base, 'Contents.json'), JSON.stringify({info:{author:'xcode',version:1}}, null, 2) + '\n');
console.log(`Wrote original ${size}x${size} RGB app icon (${png.length} bytes)`);
