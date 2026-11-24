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
  const userId = userData.user.id;

  const body = await req.json();
  const ipaSha = String(body.ipa_sha256 || "").toLowerCase();
  const reportId = String(body.report_id || "");
  const findingIds: string[] = Array.isArray(body.finding_ids) ? body.finding_ids.map(String) : [];

  if (!/^[a-f0-9]{64}$/.test(ipaSha) || !reportId) {
    return json({ error: "invalid_request" }, 400);
  }

  const { data: report } = await admin.from("security_reports").select("*").eq("id", reportId).maybeSingle();
  if (!report || report.artifact_id !== ipaSha) return json({ error: "report_not_found" }, 404);
  if (report.revoked_at) return json({ error: "report_revoked" }, 400);
  if (report.assessment_status === "blocked") return json({ error: "not_override_eligible" }, 400);
  if (report.assessment_status !== "review_required" && report.assessment_status !== "checks_passed") {
    return json({ error: "approval_not_applicable" }, 400);
  }

  const { data: findings } = await admin.from("findings").select("*").eq("report_id", reportId);
  const nonOverride = (findings || []).filter((f) => f.override_eligible === false);
  if (nonOverride.length > 0 && report.assessment_status === "review_required") {
    // Still allow if only override-eligible elevated findings exist; block if any non-override elevated
    const blocking = nonOverride.filter((f) => ["high", "critical"].includes(f.severity));
    if (blocking.length) return json({ error: "contains_non_overridable_findings", findings: blocking }, 400);
  }

  const expires = new Date(Date.now() + 30 * 86400_000).toISOString();
  const { data: approval, error } = await admin
    .from("user_approvals")
    .insert({
      user_id: userId,
      artifact_id: ipaSha,
      report_id: reportId,
      finding_ids: findingIds,
      expires_at: expires,
    })
    .select("*")
    .single();
  if (error) return json({ error: "save_failed", detail: error.message }, 500);

  await admin.from("audit_events").insert({
    actor_user_id: userId,
    event_type: "approval_recorded",
    payload: { approval_id: approval.id, report_id: reportId, ipa_sha256: ipaSha },
  });

  return json({ ok: true, approval });
});
