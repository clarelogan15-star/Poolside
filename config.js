// Poolside settings. Fill in both values from Supabase: Project Settings > API Keys / Data API.
// They are safe to put on a public website. The privacy rules in supabase/setup.sql decide what anyone can see.
window.POOLSIDE_CONFIG = {
  supabaseUrl: "",      // looks like https://abcdefghijklm.supabase.co
  supabaseAnonKey: "",  // the "publishable" key (sb_publishable_...) or the older "anon public" key
};
