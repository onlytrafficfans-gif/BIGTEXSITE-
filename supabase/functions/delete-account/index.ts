// supabase/functions/delete-account/index.ts
//
// Permanently deletes the calling user's account: their auth.users row,
// which cascades (via `on delete cascade` foreign keys, see
// supabase/migrations/0001_init_schema.sql) to profiles_data, posts, media,
// likes, comments, follows, direct_messages, notifications, reports made BY
// them, etc. -- then removes their files from the "media" storage bucket,
// which has no foreign key to clean up automatically.
//
// Deleting an auth user requires the service_role key, which must never be
// shipped to the browser. This function holds that key server-side, and
// only ever acts on the identity of whoever's JWT is presented in the
// Authorization header -- it never accepts a user id from the request body,
// so one user can never delete another user's account.
//
// Deploy: supabase functions deploy delete-account
// Invoke from the client:
//   await sb.functions.invoke('delete-account')

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return jsonResponse({ error: { code: 'METHOD_NOT_ALLOWED', message: 'Use POST.' } }, 405);
  }

  const authHeader = req.headers.get('Authorization') ?? '';
  const jwt = authHeader.replace(/^Bearer\s+/i, '');
  if (!jwt) {
    return jsonResponse({ error: { code: 'UNAUTHENTICATED', message: 'Missing session.' } }, 401);
  }

  // A client bound to the caller's own JWT, used only to resolve who they
  // are -- never to bypass RLS or act on their behalf beyond that lookup.
  const callerClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userErr } = await callerClient.auth.getUser(jwt);
  if (userErr || !userData?.user) {
    return jsonResponse({ error: { code: 'UNAUTHENTICATED', message: 'Invalid session.' } }, 401);
  }
  const userId = userData.user.id;

  const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // Best-effort storage cleanup before the account row disappears. Not
  // fatal if it fails partially -- an orphan-cleanup job can sweep any
  // objects left under this prefix later; the account deletion itself must
  // still succeed.
  try {
    const { data: files } = await adminClient.storage.from('media').list(userId, { limit: 1000 });
    if (files?.length) {
      await adminClient.storage.from('media').remove(files.map((f) => `${userId}/${f.name}`));
    }
    const { data: coverFiles } = await adminClient.storage.from('media').list(`${userId}/covers`, { limit: 1000 });
    if (coverFiles?.length) {
      await adminClient.storage.from('media').remove(coverFiles.map((f) => `${userId}/covers/${f.name}`));
    }
  } catch (storageErr) {
    console.error('delete-account: storage cleanup failed', storageErr);
  }

  const { error: deleteErr } = await adminClient.auth.admin.deleteUser(userId);
  if (deleteErr) {
    console.error('delete-account: auth.admin.deleteUser failed', deleteErr);
    return jsonResponse(
      { error: { code: 'DELETE_FAILED', message: 'Could not delete account. Please try again.' } },
      500,
    );
  }

  return jsonResponse({ ok: true });
});
