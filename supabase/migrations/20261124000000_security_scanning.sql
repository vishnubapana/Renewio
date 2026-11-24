-- Renewio shared security scanning schema
-- Apply to a dedicated Renewio Supabase project (do not use unrelated projects).

create extension if not exists pgcrypto;

-- Profiles
create table if not exists public.profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy profiles_select_own on public.profiles
  for select to authenticated using (auth.uid() = user_id);
create policy profiles_update_own on public.profiles
  for update to authenticated using (auth.uid() = user_id);
create policy profiles_insert_own on public.profiles
  for insert to authenticated with check (auth.uid() = user_id);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (user_id) values (new.id)
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Repos / releases / artifacts
create table if not exists public.repos (
  id uuid primary key default gen_random_uuid(),
  owner text not null,
  name text not null,
  canonical_url text not null,
  created_at timestamptz not null default now(),
  unique (owner, name)
);

create table if not exists public.releases (
  id uuid primary key default gen_random_uuid(),
  repo_id uuid not null references public.repos (id) on delete cascade,
  tag text not null,
  commit_sha text,
  published_at timestamptz,
  asset_id text,
  asset_name text,
  asset_size bigint,
  created_at timestamptz not null default now(),
  unique (repo_id, tag, asset_id)
);

create table if not exists public.artifacts (
  ipa_sha256 text primary key check (ipa_sha256 ~ '^[a-f0-9]{64}$'),
  release_id uuid references public.releases (id) on delete set null,
  first_seen_at timestamptz not null default now()
);

create table if not exists public.policies (
  version text primary key,
  rules jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

insert into public.policies (version, rules) values (
  'v1',
  '{
    "minimum_release_age_days": 14,
    "report_ttl_days": 30,
    "offline_grace_hours": 72,
    "scanner_bundle_version": "1.0.0"
  }'::jsonb
) on conflict (version) do nothing;

create table if not exists public.scan_jobs (
  id uuid primary key default gen_random_uuid(),
  artifact_id text not null references public.artifacts (ipa_sha256) on delete cascade,
  policy_version text not null references public.policies (version),
  scanner_bundle_version text not null,
  status text not null check (status in ('queued', 'scanning', 'succeeded', 'failed', 'timed_out')),
  dedupe_key text not null unique,
  gha_run_id text,
  error text,
  requested_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz
);

create index if not exists scan_jobs_artifact_idx on public.scan_jobs (artifact_id, policy_version);

create table if not exists public.security_reports (
  id uuid primary key default gen_random_uuid(),
  artifact_id text not null references public.artifacts (ipa_sha256) on delete cascade,
  job_id uuid not null references public.scan_jobs (id) on delete cascade,
  assessment_status text not null check (
    assessment_status in ('incomplete', 'checks_passed', 'review_required', 'blocked', 'expired', 'revoked')
  ),
  report_json jsonb not null,
  report_sha256 text not null,
  policy_version text not null references public.policies (version),
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  revoked_at timestamptz,
  revoke_reason text
);

create index if not exists security_reports_artifact_idx
  on public.security_reports (artifact_id, policy_version, created_at desc);

create table if not exists public.findings (
  id text not null,
  report_id uuid not null references public.security_reports (id) on delete cascade,
  scanner text not null,
  severity text not null,
  title text not null,
  summary text,
  override_eligible boolean not null default true,
  evidence jsonb not null default '{}'::jsonb,
  primary key (report_id, id)
);

create table if not exists public.user_approvals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  artifact_id text not null references public.artifacts (ipa_sha256) on delete cascade,
  report_id uuid not null references public.security_reports (id) on delete cascade,
  finding_ids text[] not null default '{}',
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  invalidated_at timestamptz,
  invalidate_reason text
);

create index if not exists user_approvals_lookup_idx
  on public.user_approvals (user_id, artifact_id, report_id);

create table if not exists public.user_tracked_artifacts (
  user_id uuid not null references auth.users (id) on delete cascade,
  artifact_id text not null references public.artifacts (ipa_sha256) on delete cascade,
  install_id text,
  created_at timestamptz not null default now(),
  primary key (user_id, artifact_id)
);

create table if not exists public.audit_events (
  id bigserial primary key,
  actor_user_id uuid references auth.users (id) on delete set null,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.scan_quotas (
  user_id uuid primary key references auth.users (id) on delete cascade,
  day date not null default (timezone('utc', now()))::date,
  request_count int not null default 0
);

-- RLS
alter table public.repos enable row level security;
alter table public.releases enable row level security;
alter table public.artifacts enable row level security;
alter table public.policies enable row level security;
alter table public.scan_jobs enable row level security;
alter table public.security_reports enable row level security;
alter table public.findings enable row level security;
alter table public.user_approvals enable row level security;
alter table public.user_tracked_artifacts enable row level security;
alter table public.audit_events enable row level security;
alter table public.scan_quotas enable row level security;

-- Authenticated users can read shared scan data
create policy repos_read on public.repos for select to authenticated using (true);
create policy releases_read on public.releases for select to authenticated using (true);
create policy artifacts_read on public.artifacts for select to authenticated using (true);
create policy policies_read on public.policies for select to authenticated using (true);
create policy scan_jobs_read on public.scan_jobs for select to authenticated using (true);
create policy security_reports_read on public.security_reports for select to authenticated using (true);
create policy findings_read on public.findings for select to authenticated using (true);

-- No direct client writes to shared assessment tables (Edge Functions use service role)
create policy user_approvals_own_all on public.user_approvals
  for all to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy user_tracked_own_all on public.user_tracked_artifacts
  for all to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy scan_quotas_own_select on public.scan_quotas
  for select to authenticated using (auth.uid() = user_id);

create policy audit_read_own on public.audit_events
  for select to authenticated using (actor_user_id = auth.uid());

-- Helper: latest non-revoked report for artifact+policy
create or replace function public.latest_report(p_sha text, p_policy text default 'v1')
returns public.security_reports
language sql
stable
as $$
  select *
  from public.security_reports
  where artifact_id = p_sha
    and policy_version = p_policy
    and revoked_at is null
    and (expires_at is null or expires_at > now())
  order by created_at desc
  limit 1;
$$;
