#!/usr/bin/env node
// Applies tests/supabase_stub.sql + every migration in supabase/migrations/
// + tests/rls.test.sql against a scratch Postgres database, then drops it.
// Requires a reachable Postgres (local `supabase start`, a CI service
// container, or any TEST_DATABASE_URL you point it at) -- this script does
// not spin up Postgres itself.
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const ADMIN_URL = process.env.TEST_DATABASE_ADMIN_URL || 'postgresql://postgres:postgres@localhost:5432/postgres';
const TEST_DB = process.env.TEST_DATABASE_NAME || `texx_test_${Date.now()}`;

function psql(connUrl, args, opts = {}) {
  return execFileSync('psql', [connUrl, '-v', 'ON_ERROR_STOP=1', ...args], {
    stdio: 'inherit',
    ...opts,
  });
}

function run() {
  try {
    execFileSync('psql', [ADMIN_URL, '-v', 'ON_ERROR_STOP=1', '-c', `CREATE DATABASE ${TEST_DB};`], { stdio: 'inherit' });
  } catch (err) {
    console.error('\nCould not reach Postgres / create a test database.');
    console.error('Set TEST_DATABASE_ADMIN_URL to a reachable Postgres admin connection,');
    console.error('or run `supabase start` for the local stack. See docs/DEPLOYMENT.md.');
    process.exit(1);
  }

  const testDbUrl = ADMIN_URL.replace(/\/[^/]*$/, `/${TEST_DB}`);

  try {
    psql(testDbUrl, ['-f', path.join(__dirname, '..', 'tests', 'supabase_stub.sql')]);

    const migrationsDir = path.join(__dirname, '..', 'supabase', 'migrations');
    const migrations = fs.readdirSync(migrationsDir).filter((f) => f.endsWith('.sql')).sort();
    for (const file of migrations) {
      console.log(`\n> applying ${file}`);
      psql(testDbUrl, ['-f', path.join(migrationsDir, file)]);
    }

    console.log('\n> running tests/rls.test.sql');
    psql(testDbUrl, ['-f', path.join(__dirname, '..', 'tests', 'rls.test.sql')]);

    console.log('\n✓ All SQL tests passed.');
  } catch (err) {
    console.error('\n✖ SQL tests failed.');
    process.exitCode = 1;
  } finally {
    try {
      execFileSync('psql', [ADMIN_URL, '-v', 'ON_ERROR_STOP=1', '-c', `DROP DATABASE IF EXISTS ${TEST_DB} WITH (FORCE);`], { stdio: 'inherit' });
    } catch (cleanupErr) {
      console.error(`Warning: could not drop scratch database ${TEST_DB}: ${cleanupErr.message}`);
    }
  }
}

run();
