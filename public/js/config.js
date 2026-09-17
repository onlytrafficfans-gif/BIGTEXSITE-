// Public runtime configuration for the TEXX SOCIAL frontend.
// SUPABASE_PUBLISHABLE_KEY is a Supabase "publishable" (anon) key: it is designed
// to be shipped to browsers and is safe to commit. It has no power on its own —
// every table it can touch is protected by Postgres Row Level Security policies
// defined in supabase/migrations/. Never put a service_role key here.
window.__TEXX_CONFIG__ = {
  SUPABASE_URL: 'https://iwnbsslhdqqhoocmfrik.supabase.co',
  SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_k_pAADnpnxNRn4qN6oRTrA_3eQ2-_JM',
};
