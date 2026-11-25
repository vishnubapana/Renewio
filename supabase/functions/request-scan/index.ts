import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

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

const DAILY_QUOTA = 20;
const POLICY = "v1";
const BUNDLE = "1.0.0";
const TERMINAL = new Set(["failed", "timed_out", "succeeded"]);

type JobRow = {
  id: string;
  status: string;
  [key: string]: unknown;
};

type DispatchInputs = {
  owner: string;
  repo: string;
  tag: string;
  commit: string | null;
  assetId: string | null;
  ipaSha: string;
  policyVersion: string;
  publishedAt: string | null;
};

async function resetTerminalJob(
  admin: SupabaseClient,
  jobId: string,
  userId: string,
): Promise<JobRow | null> {
  const { data, error } = await admin
    .from("scan_jobs")
    .update({
      status: "queued",
      error: null,
      completed_at: null,
      gha_run_id: null,
      requested_by: userId,
      updated_at: new Date().toISOString(),
    })
    .eq("id", jobId)
    .select("*")
    .single();
  if (error || !data) return null;
  return data as JobRow;
}

async function dispatchScan(
  admin: SupabaseClient,
  jobId: string,
  userId: string,
  supabaseUrl: string,
  inputs: DispatchInputs,
): Promise<Response | null> {
  const ghToken = Deno.env.get("GITHUB_DISPATCH_TOKEN");
  const ghRepo = Deno.env.get("SCANNER_GITHUB_REPO"); // owner/repo
  const callbackUrl = `${supabaseUrl}/functions/v1/submit-report`;

  if (!ghToken || !ghRepo) {
    await admin.from("audit_events").insert({
      actor_user_id: userId,
      event_type: "scan_queued_no_dispatch",
      payload: { job_id: jobId, reason: "missing GITHUB_DISPATCH_TOKEN or SCANNER_GITHUB_REPO" },
    });
    return null;
  }

  try {
    const resp = await fetch(
      `https://api.github.com/repos/${ghRepo}/actions/workflows/scan-release.yml/dispatches`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${ghToken}`,
          Accept: "application/vnd.github+json",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          ref: "main",
          inputs: {
            job_id: jobId,
            github_owner: inputs.owner,
            github_repo: inputs.repo,
            release_tag: inputs.tag,
            source_commit: inputs.commit || "",
            asset_id: inputs.assetId || "",
            expected_sha256: inputs.ipaSha,
            policy_version: inputs.policyVersion,
            callback_url: callbackUrl,
            published_at: inputs.publishedAt || "",
          },
        }),
      },
    );
    if (!resp.ok) {
      const detail = await resp.text();
      await admin.from("scan_jobs").update({
        status: "failed",
        error: `gha_dispatch_failed: ${detail.slice(0, 500)}`,
        updated_at: new Date().toISOString(),
      }).eq("id", jobId);
      return json({ error: "gha_dispatch_failed", detail }, 502);
    }
    await admin.from("scan_jobs").update({
      status: "scanning",
      updated_at: new Date().toISOString(),
    }).eq("id", jobId);
  } catch (e) {
    const detail = String(e);
    await admin.from("scan_jobs").update({
      status: "failed",
      error: detail,
      updated_at: new Date().toISOString(),
    }).eq("id", jobId);
    return json({ error: "gha_dispatch_failed", detail }, 502);
  }

  return null;
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

  const { data: userData, error: userErr } = await userSb.auth.getUser();
  if (userErr || !userData.user) return json({ error: "unauthorized" }, 401);
  const userId = userData.user.id;

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const ipaSha = String(body.ipa_sha256 || "").toLowerCase();
  const owner = String(body.github_owner || "");
  const repo = String(body.github_repo || "");
  const tag = String(body.release_tag || "");
  const commit = body.source_commit ? String(body.source_commit) : null;
  const assetId = body.asset_id != null ? String(body.asset_id) : null;
  const assetName = body.asset_name ? String(body.asset_name) : null;
  const publishedAt = body.published_at ? String(body.published_at) : null;
  const policyVersion = String(body.policy_version || POLICY);

  if (!/^[a-f0-9]{64}$/.test(ipaSha) || !owner || !repo || !tag) {
    return json({ error: "invalid_artifact_identity" }, 400);
  }

  // Quota
  const day = new Date().toISOString().slice(0, 10);
  const { data: quota } = await admin.from("scan_quotas").select("*").eq("user_id", userId).maybeSingle();
  if (quota && quota.day === day && quota.request_count >= DAILY_QUOTA) {
    return json({ error: "daily_quota_exceeded", limit: DAILY_QUOTA }, 429);
  }
  if (!quota || quota.day !== day) {
    await admin.from("scan_quotas").upsert({ user_id: userId, day, request_count: 1 });
  } else {
    await admin.from("scan_quotas").update({ request_count: quota.request_count + 1 }).eq("user_id", userId);
  }

  // Upsert repo / release / artifact
  const { data: repoRow, error: repoErr } = await admin
    .from("repos")
    .upsert(
      { owner, name: repo, canonical_url: `https://github.com/${owner}/${repo}` },
      { onConflict: "owner,name" },
    )
    .select("*")
    .single();
  if (repoErr) return json({ error: "repo_upsert_failed", detail: repoErr.message }, 500);

  const { data: releaseRow, error: relErr } = await admin
    .from("releases")
    .upsert(
      {
        repo_id: repoRow.id,
        tag,
        commit_sha: commit,
        published_at: publishedAt,
        asset_id: assetId,
        asset_name: assetName,
      },
      { onConflict: "repo_id,tag,asset_id" },
    )
    .select("*")
    .single();
  if (relErr) return json({ error: "release_upsert_failed", detail: relErr.message }, 500);

  await admin.from("artifacts").upsert({ ipa_sha256: ipaSha, release_id: releaseRow.id });

  const dedupeKey = `${ipaSha}|${policyVersion}|${BUNDLE}`;
  const dispatchInputs: DispatchInputs = {
    owner,
    repo,
    tag,
    commit,
    assetId,
    ipaSha,
    policyVersion,
    publishedAt,
  };

  // Existing valid report?
  const { data: existingReport } = await admin
    .from("security_reports")
    .select("*")
    .eq("artifact_id", ipaSha)
    .eq("policy_version", policyVersion)
    .is("revoked_at", null)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (existingReport && (!existingReport.expires_at || new Date(existingReport.expires_at) > new Date())) {
    await admin.from("audit_events").insert({
      actor_user_id: userId,
      event_type: "scan_cache_hit",
      payload: { ipa_sha256: ipaSha, report_id: existingReport.id },
    });
    return json({
      job_id: existingReport.job_id,
      status: "succeeded",
      scan_status: "succeeded",
      assessment_status: existingReport.assessment_status,
      report_id: existingReport.id,
      report: existingReport.report_json,
    });
  }

  // In-flight job?
  const { data: inflight } = await admin
    .from("scan_jobs")
    .select("*")
    .eq("dedupe_key", dedupeKey)
    .in("status", ["queued", "scanning"])
    .maybeSingle();

  if (inflight) {
    return json({
      job_id: inflight.id,
      status: inflight.status,
      scan_status: inflight.status,
      assessment_status: null,
      report_id: null,
    });
  }

  // Reuse terminal row for this dedupe_key (unique constraint) instead of insert-failing forever.
  const { data: existingJob } = await admin
    .from("scan_jobs")
    .select("*")
    .eq("dedupe_key", dedupeKey)
    .maybeSingle();

  let job: JobRow | null = null;

  if (existingJob && TERMINAL.has(String(existingJob.status))) {
    job = await resetTerminalJob(admin, existingJob.id, userId);
    if (!job) return json({ error: "job_reset_failed" }, 500);
  } else if (!existingJob) {
    const { data: inserted, error: jobErr } = await admin
      .from("scan_jobs")
      .insert({
        artifact_id: ipaSha,
        policy_version: policyVersion,
        scanner_bundle_version: BUNDLE,
        status: "queued",
        dedupe_key: dedupeKey,
        requested_by: userId,
      })
      .select("*")
      .single();

    if (jobErr) {
      // Race: another insert won — re-read and handle.
      const { data: raced } = await admin.from("scan_jobs").select("*").eq("dedupe_key", dedupeKey).maybeSingle();
      if (!raced) return json({ error: "job_create_failed", detail: jobErr.message }, 500);

      if (raced.status === "queued" || raced.status === "scanning") {
        return json({
          job_id: raced.id,
          status: raced.status,
          scan_status: raced.status,
          assessment_status: null,
          report_id: null,
        });
      }

      if (TERMINAL.has(String(raced.status))) {
        job = await resetTerminalJob(admin, raced.id, userId);
        if (!job) return json({ error: "job_reset_failed" }, 500);
      } else {
        return json({ error: "job_create_failed", detail: jobErr.message }, 500);
      }
    } else {
      job = inserted as JobRow;
    }
  } else {
    // Unexpected non-terminal, non-inflight status — treat as race return.
    return json({
      job_id: existingJob.id,
      status: existingJob.status,
      scan_status: existingJob.status,
      assessment_status: null,
      report_id: null,
    });
  }

  if (!job) return json({ error: "job_create_failed" }, 500);

  const dispatchFail = await dispatchScan(admin, job.id, userId, supabaseUrl, dispatchInputs);
  if (dispatchFail) return dispatchFail;

  const ghToken = Deno.env.get("GITHUB_DISPATCH_TOKEN");
  const ghRepo = Deno.env.get("SCANNER_GITHUB_REPO");

  await admin.from("audit_events").insert({
    actor_user_id: userId,
    event_type: "scan_requested",
    payload: { job_id: job.id, ipa_sha256: ipaSha },
  });

  return json({
    job_id: job.id,
    status: ghToken && ghRepo ? "scanning" : "queued",
    scan_status: ghToken && ghRepo ? "scanning" : "queued",
    assessment_status: null,
    report_id: null,
  });
});
