import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-renewio-signature, x-renewio-job-id",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "unauthorized" }, 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const userSb = createClient(supabaseUrl, anon, {
    global: { headers: { Authorization: authHeader } },
  });
  const admin = createClient(supabaseUrl, serviceKey);

  const { data: userData } = await userSb.auth.getUser();
  if (!userData.user) return json({ error: "unauthorized" }, 401);

  const body = await req.json();
  const approvalId = String(body.approval_id || "");
  if (!approvalId) return json({ error: "invalid_request" }, 400);

  const { data: row } = await admin.from("user_approvals").select("*").eq("id", approvalId).maybeSingle();
  if (!row || row.user_id !== userData.user.id) return json({ error: "not_found" }, 404);

  await admin.from("user_approvals").update({
    invalidated_at: new Date().toISOString(),
    invalidate_reason: "user_revoked",
  }).eq("id", approvalId);

  await admin.from("audit_events").insert({
    actor_user_id: userData.user.id,
    event_type: "approval_revoked",
    payload: { approval_id: approvalId },
  });

  return json({ ok: true });
});
