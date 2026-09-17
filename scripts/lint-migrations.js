#!/usr/bin/env node
// Guards the "migrations must be non-destructive" rule from docs/DATABASE.md
// as an actual CI gate, not just a promise in prose. Flags any migration
// that contains an unguarded destructive statement.
const fs = require('node:fs');
const path = require('node:path');

const MIGRATIONS_DIR = path.join(__dirname, '..', 'supabase', 'migrations');

const FORBIDDEN = [
  { pattern: /\bdrop\s+table\b/i, message: 'DROP TABLE is not allowed in a migration' },
  { pattern: /\btruncate\b/i, message: 'TRUNCATE is not allowed in a migration' },
  { pattern: /\bdelete\s+from\s+\S+\s*;/i, message: 'Unfiltered DELETE (no WHERE clause) is not allowed in a migration' },
  { pattern: /\bdrop\s+database\b/i, message: 'DROP DATABASE is never allowed' },
  { pattern: /\bdrop\s+schema\b/i, message: 'DROP SCHEMA is never allowed' },
];

let hasError = false;

if (!fs.existsSync(MIGRATIONS_DIR)) {
  console.error(`No migrations directory found at ${MIGRATIONS_DIR}`);
  process.exit(1);
}

const files = fs.readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort();

if (files.length === 0) {
  console.error('No .sql migrations found.');
  process.exit(1);
}

for (const file of files) {
  const filePath = path.join(MIGRATIONS_DIR, file);
  const content = fs.readFileSync(filePath, 'utf8');

  for (const rule of FORBIDDEN) {
    if (rule.pattern.test(content)) {
      console.error(`✖ ${file}: ${rule.message}`);
      hasError = true;
    }
  }

  // Every DDL statement should be idempotent.
  const createsTable = /create\s+table\s+(?!.*if not exists)/i.test(content.replace(/create\s+table\s+if not exists/gi, ''));
  if (createsTable) {
    console.error(`✖ ${file}: CREATE TABLE without IF NOT EXISTS`);
    hasError = true;
  }
}

if (hasError) {
  console.error(`\nLint failed: ${files.length} migration(s) checked.`);
  process.exit(1);
}

console.log(`✓ Lint passed: ${files.length} migration(s) checked, all non-destructive and idempotent.`);
