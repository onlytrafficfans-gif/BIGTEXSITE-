#!/usr/bin/env node
// There is no bundler for this static frontend, so "build" is a structural
// sanity check: every asset public/index.html references must exist, and
// the HTML must contain no leftover data: URIs or unresolved template
// placeholders from the migration off of the original production page.
const fs = require('node:fs');
const path = require('node:path');

const PUBLIC_DIR = path.join(__dirname, '..', 'public');
const INDEX = path.join(PUBLIC_DIR, 'index.html');

let hasError = false;

if (!fs.existsSync(INDEX)) {
  console.error(`✖ Missing ${INDEX}`);
  process.exit(1);
}

const html = fs.readFileSync(INDEX, 'utf8');

if (html.includes('__ASSET__')) {
  console.error('✖ index.html contains an unresolved __ASSET__ placeholder');
  hasError = true;
}

if (/data:image\/[a-z+.-]+;base64,[A-Za-z0-9+/=]{200,}/.test(html)) {
  console.error('✖ index.html contains a large inline base64 image (should be a real asset file)');
  hasError = true;
}

const refs = [...html.matchAll(/(?:href|src)="(\/[^"]+)"/g)].map((m) => m[1]);
for (const ref of refs) {
  const refPath = path.join(PUBLIC_DIR, ref);
  if (!fs.existsSync(refPath)) {
    console.error(`✖ index.html references missing file: ${ref}`);
    hasError = true;
  }
}

if (hasError) {
  console.error('\nBuild check failed.');
  process.exit(1);
}

console.log(`✓ Build check passed: ${refs.length} local asset reference(s) resolved, no unresolved placeholders.`);
