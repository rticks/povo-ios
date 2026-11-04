const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {execFileSync} = require('node:child_process');
const root = path.resolve(__dirname, '..');
const core = path.resolve(process.argv[2]);
const android = path.resolve(process.argv[3]);
function git(dir, args) { return execFileSync('git', ['-C', dir, ...args], {encoding:'utf8'}).trim(); }
function hash(file) { return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'); }
function source(dir, url) {
  const dirty = git(dir, ['diff', '--name-only', 'HEAD']).split('\n').filter(Boolean);
  return {url, commit:git(dir, ['rev-parse', 'HEAD']), local_changes:dirty.map(file => ({file,sha256:hash(path.join(dir,file))}))};
}
function walk(dir) {
  return fs.readdirSync(dir, {withFileTypes:true}).flatMap(e => e.isDirectory() ? walk(path.join(dir,e.name)) : [path.join(dir,e.name)]);
}
const report = {
  recorded_at:new Date().toISOString(),
  core:source(core,'https://github.com/uirooong/povo-core'),
  android:source(android,'https://github.com/uirooong/povo-android'),
  vendored_core:walk(path.join(root,'vendor/povo-core')).map(file => ({file:path.relative(root,file).replaceAll('\\','/'),sha256:hash(file)})),
  fixtures:walk(path.join(root,'Packages/PovoKit/Tests/PovoKitTests/Fixtures')).map(file => ({file:path.relative(root,file).replaceAll('\\','/'),sha256:hash(file)}))
};
fs.writeFileSync(path.join(root,'docs/SOURCE-PROVENANCE.json'),JSON.stringify(report,null,2)+'\n');
console.log(`Recorded ${report.vendored_core.length} core files and ${report.fixtures.length} anonymised fixtures`);
