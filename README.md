# Poolside

A swim lesson manager for one coach, with a public booking page for parents.

- `index.html`: the coach app (schedule, booking requests, families, skill progress, AI lesson plans, AI video feedback, AI parent updates). Add it to an iPhone home screen from Safari.
- `book.html`: the parent booking page. Anyone with the link sees only open times and can request one.
- `config.js`: the Supabase Project URL and publishable key. Both are public by design.
- `supabase/setup.sql`: tables and privacy rules. Run it once in the Supabase SQL Editor.
- `supabase/functions/claude/index.ts`: the AI helper (Supabase Edge Function). It keeps the Anthropic key secret and only answers the signed-in coach.

Without `config.js` filled in, the app runs in demo mode with example data and saves nothing.
