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

async function hmacHex(secret: string, body: ArrayBuffer): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, body);
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256Hex(body: ArrayBuffer): Promise<string> {
  const dig = await crypto.subtle.digest("SHA-256", body);
  return [...new Uint8Array(dig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const secret = Deno.env.get("SUBMIT_REPORT_HMAC_SECRET");
  if (!secret) return json({ error: "server_misconfigured" }, 500);

  const raw = await req.arrayBuffer();
  const provided = (req.headers.get("X-Renewio-Signature") || "").toLowerCase();
  const expected = await hmacHex(secret, raw);
  if (!provided || provided !== expected) {
    return json({ error: "invalid_signature" }, 401);
  }

  let report: Record<string, unknown>;
  try {
    report = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const jobId = String(report.job_id || "");
  const artifact = report.artifact as Record<string, unknown> | undefined;
  const ipaSha = String(artifact?.ipa_sha256 || "").toLowerCase();
  const assessment = String(report.assessment_status || "incomplete");
  const policyVersion = String(report.policy_version || "v1");
  if (!jobId || !/^[a-f0-9]{64}$/.test(ipaSha)) {
    return json({ error: "invalid_report" }, 400);
  }

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: job } = await admin.from("scan_jobs").select("*").eq("id", jobId).maybeSingle();
  if (!job) return json({ error: "unknown_job" }, 404);
  if (job.artifact_id !== ipaSha) return json({ error: "artifact_mismatch" }, 400);

  const reportSha = await sha256Hex(raw);
  const ttlDays = 30;
  const expires = new Date(Date.now() + ttlDays * 86400_000).toISOString();

  const { data: saved, error: saveErr } = await admin
    .from("security_reports")
    .insert({
      artifact_id: ipaSha,
      job_id: jobId,
      assessment_status: assessment,
      report_json: report,
      report_sha256: reportSha,
      policy_version: policyVersion,
      expires_at: expires,
    })
    .select("*")
    .single();
  if (saveErr) return json({ error: "save_failed", detail: saveErr.message }, 500);

  const findings = Array.isArray(report.findings) ? report.findings as Record<string, unknown>[] : [];
  if (findings.length) {
    const rows = findings.map((f) => ({
      id: String(f.id),
      report_id: saved.id,
      scanner: String(f.scanner || "unknown"),
      severity: String(f.severity || "unknown"),
      title: String(f.title || ""),
      summary: f.summary ? String(f.summary) : null,
      override_eligible: f.override_eligible !== false,
      evidence: f.evidence || {},
    }));
    await admin.from("findings").upsert(rows);
  }

  // Invalidate prior approvals if assessment worsened materially
  if (assessment === "blocked" || assessment === "review_required" || assessment === "incomplete") {
    await admin
      .from("user_approvals")
      .update({ invalidated_at: new Date().toISOString(), invalidate_reason: "new_report_revision" })
      .eq("artifact_id", ipaSha)
      .is("invalidated_at", null)
      .neq("report_id", saved.id);
  }

  await admin.from("scan_jobs").update({
    status: assessment === "incomplete" ? "failed" : "succeeded",
    error: assessment === "incomplete" ? "incomplete_assessment" : null,
    completed_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  }).eq("id", jobId);

  await admin.from("audit_events").insert({
    event_type: "report_submitted",
    payload: { job_id: jobId, report_id: saved.id, assessment_status: assessment },
  });

  return json({ ok: true, report_id: saved.id, assessment_status: assessment });
});
