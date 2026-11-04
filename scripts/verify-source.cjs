const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '..');
const report = JSON.parse(fs.readFileSync(path.join(root, 'docs/SOURCE-PROVENANCE.json'), 'utf8'));
let checked = 0;
for (const entry of [...report.vendored_core, ...report.fixtures]) {
  const file = path.resolve(root, entry.file);
  if (!file.startsWith(root + path.sep)) throw new Error('Snapshot path escapes repository');
  const actual = crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  if (actual !== entry.sha256) throw new Error(`Snapshot hash mismatch: ${entry.file}`);
  checked++;
}
console.log(`Verified ${checked} pinned source/fixture SHA-256 hashes`);
