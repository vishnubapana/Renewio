import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-renewio-cron-secret",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

/**
 * Phase 4: cron/admin entrypoint to mark artifacts for vuln-only re-evaluation.
 * Full rescan is triggered by clearing dedupe and enqueueing new jobs for tracked artifacts.
 * Protected by RENEWIO_CRON_SECRET (not user JWT).
 */
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const cronSecret = Deno.env.get("RENEWIO_CRON_SECRET");
  const provided = req.headers.get("X-Renewio-Cron-Secret");
  if (!cronSecret || provided !== cronSecret) return json({ error: "unauthorized" }, 401);

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const body = await req.json().catch(() => ({}));
  const limit = Math.min(Number(body.limit || 25), 100);

  // Expire old reports
  const { data: expired } = await admin
    .from("security_reports")
    .update({ assessment_status: "expired" })
    .lt("expires_at", new Date().toISOString())
    .is("revoked_at", null)
    .neq("assessment_status", "expired")
    .select("id, artifact_id");

  // Invalidate approvals tied to expired reports
  for (const r of expired || []) {
    await admin
      .from("user_approvals")
      .update({ invalidated_at: new Date().toISOString(), invalidate_reason: "report_expired" })
      .eq("report_id", r.id)
      .is("invalidated_at", null);
  }

  // Select tracked artifacts with oldest reports for re-queue hint
  const { data: tracked } = await admin
    .from("user_tracked_artifacts")
    .select("artifact_id")
    .limit(limit);

  const unique = [...new Set((tracked || []).map((t) => t.artifact_id))];

  await admin.from("audit_events").insert({
    event_type: "vuln_recheck_pass",
    payload: {
      expired_count: (expired || []).length,
      tracked_candidates: unique,
      note: "Clients should request_scan again for candidates; dedupe_key includes bundle version",
    },
  });

  return json({
    ok: true,
    expired_reports: (expired || []).length,
    recheck_candidates: unique,
  });
});
