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
  if (req.method !== "GET") return json({ error: "method_not_allowed" }, 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "unauthorized" }, 401);

  const url = new URL(req.url);
  const jobId = url.searchParams.get("job_id");
  const ipaSha = (url.searchParams.get("ipa_sha256") || "").toLowerCase();

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const userSb = createClient(supabaseUrl, anon, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData } = await userSb.auth.getUser();
  if (!userData.user) return json({ error: "unauthorized" }, 401);

  const admin = createClient(supabaseUrl, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  let job = null;
  if (jobId) {
    const { data } = await admin.from("scan_jobs").select("*").eq("id", jobId).maybeSingle();
    job = data;
  } else if (/^[a-f0-9]{64}$/.test(ipaSha)) {
    const { data } = await admin
      .from("scan_jobs")
      .select("*")
      .eq("artifact_id", ipaSha)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    job = data;
  } else {
    return json({ error: "job_id_or_ipa_sha256_required" }, 400);
  }

  if (!job) return json({ error: "not_found" }, 404);

  const { data: report } = await admin
    .from("security_reports")
    .select("id, assessment_status, report_sha256, created_at, expires_at, revoked_at")
    .eq("job_id", job.id)
    .maybeSingle();

  return json({
    job_id: job.id,
    status: job.status,
    scan_status: job.status,
    error: job.error,
    report,
  });
});
