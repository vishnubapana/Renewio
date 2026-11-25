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

type ApprovalState = "none" | "valid" | "expired" | "invalidated";

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
  const policyVersion = String(body.policy_version || "v1");
  const isAuto = Boolean(body.is_auto_renew);
  const offlineGraceHours = Number(body.offline_grace_hours ?? 72);
  const localReportSha = body.local_report_sha256 ? String(body.local_report_sha256) : null;
  const localAssessment = body.local_assessment_status ? String(body.local_assessment_status) : null;
  const localCheckedAt = body.local_checked_at ? new Date(String(body.local_checked_at)) : null;

  if (!/^[a-f0-9]{64}$/.test(ipaSha)) return json({ error: "invalid_sha" }, 400);

  const { data: job } = await admin
    .from("scan_jobs")
    .select("*")
    .eq("artifact_id", ipaSha)
    .eq("policy_version", policyVersion)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  const { data: report } = await admin
    .from("security_reports")
    .select("*")
    .eq("artifact_id", ipaSha)
    .eq("policy_version", policyVersion)
    .is("revoked_at", null)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  // Offline / backend path is client-side; here we always have backend.
  // If no report yet:
  if (!report) {
    const scanStatus = job?.status || "not_scanned";
    if (scanStatus === "queued" || scanStatus === "scanning") {
      return json({
        scan_status: scanStatus,
        assessment_status: null,
        install_eligibility: "pending",
        report_id: null,
        ipa_sha256: ipaSha,
        limitations: [],
        findings_summary: {},
        user_approval: null,
        reasons: ["scan_in_progress"],
      });
    }
    if (scanStatus === "failed" || scanStatus === "timed_out") {
      return json({
        scan_status: scanStatus,
        assessment_status: "incomplete",
        install_eligibility: "deny",
        report_id: null,
        ipa_sha256: ipaSha,
        limitations: ["scan_failed"],
        findings_summary: {},
        user_approval: null,
        reasons: ["scan_failed"],
      });
    }
    // Offline grace hint for client (same-artifact renew only)
    if (localReportSha && localAssessment && localCheckedAt) {
      const ageH = (Date.now() - localCheckedAt.getTime()) / 3600_000;
      if (ageH <= offlineGraceHours &&
        (localAssessment === "checks_passed" || localAssessment === "review_required")) {
        return json({
          scan_status: "succeeded",
          assessment_status: localAssessment,
          install_eligibility: localAssessment === "checks_passed" ? "allow" : "allow_with_approval",
          report_id: null,
          ipa_sha256: ipaSha,
          limitations: ["using_local_cached_report"],
          findings_summary: {},
          user_approval: null,
          reasons: ["offline_grace_candidate"],
          offline_grace: true,
        });
      }
    }
    return json({
      scan_status: "not_scanned",
      assessment_status: null,
      install_eligibility: "deny",
      report_id: null,
      ipa_sha256: ipaSha,
      limitations: [],
      findings_summary: {},
      user_approval: null,
      reasons: ["not_scanned"],
    });
  }

  if (report.expires_at && new Date(report.expires_at) <= new Date()) {
    return json({
      scan_status: "succeeded",
      assessment_status: "expired",
      install_eligibility: "deny",
      report_id: report.id,
      ipa_sha256: ipaSha,
      limitations: ["report_expired"],
      findings_summary: {},
      user_approval: null,
      reasons: ["report_expired"],
    });
  }

  const { data: findings } = await admin.from("findings").select("*").eq("report_id", report.id);
  const summary: Record<string, number> = {};
  for (const f of findings || []) {
    summary[f.severity] = (summary[f.severity] || 0) + 1;
  }

  const { data: approval } = await admin
    .from("user_approvals")
    .select("*")
    .eq("user_id", userId)
    .eq("artifact_id", ipaSha)
    .eq("report_id", report.id)
    .is("invalidated_at", null)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  let approvalState: ApprovalState = "none";
  if (approval) {
    if (approval.expires_at && new Date(approval.expires_at) <= new Date()) approvalState = "expired";
    else approvalState = "valid";
  }

  const assessment = report.assessment_status as string;
  let eligibility = "deny";
  const reasons: string[] = [];

  if (assessment === "blocked" || assessment === "revoked") {
    eligibility = "deny";
    reasons.push(assessment);
  } else if (assessment === "incomplete") {
    eligibility = "deny";
    reasons.push("incomplete_assessment");
  } else if (assessment === "checks_passed") {
    eligibility = "allow";
    reasons.push("checks_passed");
  } else if (assessment === "review_required") {
    if (approvalState === "valid") {
      eligibility = "allow";
      reasons.push("user_approval_valid");
    } else if (isAuto) {
      eligibility = "deny";
      reasons.push("auto_requires_approval");
    } else {
      eligibility = "allow_with_approval";
      reasons.push("review_required");
    }
  } else {
    eligibility = "deny";
    reasons.push("unknown_assessment");
  }

  const limitations = Array.isArray((report.report_json as { limitations?: string[] })?.limitations)
    ? (report.report_json as { limitations: string[] }).limitations
    : [];

  return json({
    scan_status: "succeeded",
    assessment_status: assessment,
    install_eligibility: eligibility,
    report_id: report.id,
    report_sha256: report.report_sha256,
    ipa_sha256: ipaSha,
    limitations,
    findings_summary: summary,
    findings: findings || [],
    report: report.report_json,
    user_approval: approvalState === "none" ? null : { state: approvalState, id: approval?.id },
    reasons,
  });
});
