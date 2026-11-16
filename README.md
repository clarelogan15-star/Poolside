# Poolside

A swim lesson manager for one coach, with a public booking page for parents.

- `index.html`: the coach app (schedule, booking requests, families, skill progress, AI lesson plans, AI video feedback, AI parent updates). Add it to an iPhone home screen from Safari.
- `book.html`: the parent booking page. Anyone with the link sees only open times and can request one.
- `config.js`: the Supabase Project URL and publishable key. Both are public by design.
- `supabase/setup.sql`: tables and privacy rules. Run it once in the Supabase SQL Editor.
- `supabase/functions/claude/index.ts`: the AI helper (Supabase Edge Function). It keeps the Anthropic key secret and only answers the signed-in coach.

Without `config.js` filled in, the app runs in demo mode with example data and saves nothing.

## Guest coach accounts (update 3)

After running `supabase/update-3-classmate-accounts.sql`, anyone can create an account on the sign-in screen. Each account gets its own private space, starts with made-up example families, and has its own booking link (`book.html?c=<account id>`). The original coach (the email in the `coach` table) keeps all existing data, the plain booking link, and unlimited AI. Other accounts get 15 AI uses a day, with 250 a day across all of them; change the numbers in `ai_limits()` and run the file again. "Just look around" on the sign-in screen opens example data with no account and no AI.
