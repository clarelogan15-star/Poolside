// Poolside's AI helper. Runs on Supabase (Edge Functions) and keeps the Anthropic key off the website.
// Only the signed-in coach can use it. Needs the secret ANTHROPIC_API_KEY set in Supabase.
import Anthropic from "npm:@anthropic-ai/sdk@0.137.0";
import { createClient } from "npm:@supabase/supabase-js@2.118.0";

const MODEL = "claude-opus-5-5";
const MAX_IMAGES = 8;
const MAX_IMAGE_CHARS = 4_000_000; // base64 characters per frame
const MAX_PROMPT_CHARS = 100_000;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "bad_request" }, 405);

  // Only the coach listed in the database may spend AI credit.
  const publicKey = req.headers.get("apikey") ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, publicKey, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: isCoach, error: authError } = await supabase.rpc("is_coach");
  if (authError || isCoach !== true) return reply({ error: "not_granted" }, 403);

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return reply({ error: "no_key" }, 500);

  let body: { prompt?: unknown; images?: unknown; json?: unknown };
  try { body = await req.json(); } catch { return reply({ error: "bad_request" }, 400); }
  const prompt = typeof body.prompt === "string" ? body.prompt : "";
  const images = Array.isArray(body.images) ? body.images : [];
  if (!prompt || prompt.length > MAX_PROMPT_CHARS) return reply({ error: "bad_request" }, 400);
  if (images.length > MAX_IMAGES || images.some((d) => typeof d !== "string" || d.length > MAX_IMAGE_CHARS)) {
    return reply({ error: "image_rejected" }, 400);
  }

  const content: Anthropic.Beta.BetaContentBlockParam[] = [
    ...(images as string[]).map((data) => ({
      type: "image" as const,
      source: { type: "base64" as const, media_type: "image/jpeg" as const, data },
    })),
    { type: "text", text: body.json ? `${prompt}\n\nReply with only the JSON object and nothing else.` : prompt },
  ];

  const client = new Anthropic({ apiKey });
  try {
    const message = await client.beta.messages.create({
      model: MODEL,
      max_tokens: 16000,
      output_config: { effort: "medium" },
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      messages: [{ role: "user", content }],
    });
    if (message.stop_reason === "refusal") return reply({ error: "refusal" }, 422);
    const text = message.content.map((b) => (b.type === "text" ? b.text : "")).join("").trim();
    if (!text) return reply({ error: "empty" }, 502);
    return reply({ text, truncated: message.stop_reason === "max_tokens" });
  } catch (err) {
    if (err instanceof Anthropic.AuthenticationError) return reply({ error: "bad_key" }, 500);
    if (err instanceof Anthropic.PermissionDeniedError) return reply({ error: "bad_key" }, 500);
    if (err instanceof Anthropic.RateLimitError) return reply({ error: "rate_limited" }, 429);
    if (err instanceof Anthropic.BadRequestError) {
      console.error("Anthropic rejected the request:", err.message);
      return reply({ error: "rejected" }, 400);
    }
    if (err instanceof Anthropic.APIError) {
      console.error(`Anthropic error ${err.status}:`, err.message);
      return reply({ error: "busy" }, 503);
    }
    console.error(err);
    return reply({ error: "busy" }, 503);
  }
});
