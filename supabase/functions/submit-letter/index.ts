// Supabase Edge Function: validates, checks the honeypot and (optionally) Turnstile, then calls submit_letter.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "content-type, authorization, apikey" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const b = await req.json().catch(() => null);
  if (!b || b.website) return json({ error: "rejected" }, 400);               // honeypot
  const title = String(b.title ?? "").trim(), body = String(b.body ?? "").trim();
  if (title.length < 3 || title.length > 90 || body.length < 40 || body.length > 3000) return json({ error: "invalid" }, 400);

  const secret = Deno.env.get("TURNSTILE_SECRET");
  if (secret) {
    const r = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
      method: "POST", body: new URLSearchParams({ secret, response: String(b.turnstile ?? "") }),
    });
    if (!(await r.json()).success) return json({ error: "captcha" }, 400);
  }

  const ip = req.headers.get("x-forwarded-for")?.split(",")[0] ?? "unknown";
  const hash = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",
    new TextEncoder().encode(ip + Deno.env.get("IP_SALT")))), (x) => x.toString(16).padStart(2, "0")).join("");

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { error } = await db.rpc("submit_letter", {
    p_title: title, p_body: body, p_category: b.category ?? "", p_mood: b.mood ?? "", p_consent: b.consent === true, p_ip_hash: hash,
  });
  if (error) return json({ error: error.message }, error.message.includes("rate") ? 429 : 400);
  return json({ ok: true });
});
