-- OrderDesk NG Monitoring Centre
-- Safe additive migration: creates isolated monitoring storage and owner-only read RPCs.
-- Does not modify existing business, order, payment, subscription, or support records.

create table if not exists public.orderdesk_monitoring_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null check (event_type in ('browser_error','unhandled_rejection','resource_error','web_vital','server_error')),
  severity text not null default 'error' check (severity in ('error','warning','info')),
  source text not null default 'browser',
  page_path text not null default '/',
  message text not null,
  stack text,
  fingerprint text not null,
  user_agent text,
  metric_name text,
  metric_value numeric,
  metric_rating text check (metric_rating is null or metric_rating in ('good','needs-improvement','poor')),
  metadata jsonb not null default '{}'::jsonb,
  client_ip_hash text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references auth.users(id) on delete set null
);

create index if not exists orderdesk_monitoring_created_idx on public.orderdesk_monitoring_events(created_at desc);
create index if not exists orderdesk_monitoring_unresolved_idx on public.orderdesk_monitoring_events(created_at desc) where resolved_at is null;
create index if not exists orderdesk_monitoring_fingerprint_idx on public.orderdesk_monitoring_events(fingerprint, created_at desc);
create index if not exists orderdesk_monitoring_ip_rate_idx on public.orderdesk_monitoring_events(client_ip_hash, created_at desc) where client_ip_hash is not null;
create index if not exists orderdesk_monitoring_type_idx on public.orderdesk_monitoring_events(event_type, created_at desc);

alter table public.orderdesk_monitoring_events add column if not exists client_ip_hash text;
alter table public.orderdesk_monitoring_events enable row level security;
revoke all on public.orderdesk_monitoring_events from anon, authenticated;
grant all on public.orderdesk_monitoring_events to service_role;

create or replace function public.owner_monitoring_overview()
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare result jsonb;
begin
  if coalesce(public.owner_is_admin(), false) is not true then raise exception 'Not authorised'; end if;
  select jsonb_build_object(
    'errors_24h', count(*) filter (where event_type <> 'web_vital' and created_at >= now()-interval '24 hours'),
    'errors_7d', count(*) filter (where event_type <> 'web_vital' and created_at >= now()-interval '7 days'),
    'unresolved', count(*) filter (where event_type <> 'web_vital' and resolved_at is null),
    'critical_24h', count(*) filter (where severity='error' and event_type <> 'web_vital' and created_at >= now()-interval '24 hours'),
    'vitals_24h', count(*) filter (where event_type='web_vital' and created_at >= now()-interval '24 hours'),
    'last_event_at', max(created_at),
    'daily_errors', coalesce((select jsonb_agg(jsonb_build_object('day',to_char(gs.series_timestamp::date,'Dy'),'date',gs.series_timestamp::date,'count',coalesce(daily_counts.event_count,0)) order by gs.series_timestamp) from generate_series(current_date - 6, current_date, interval '1 day') as gs(series_timestamp) left join (select created_at::date as event_date, count(*) as event_count from public.orderdesk_monitoring_events where event_type <> 'web_vital' and created_at >= current_date - 6 group by created_at::date) daily_counts on daily_counts.event_date = gs.series_timestamp::date),'[]'::jsonb),
    'top_errors', coalesce((select jsonb_agg(to_jsonb(t)) from (
      select fingerprint, left(message,180) message, source, page_path, count(*) occurrences, count(distinct metadata->>'session_id') filter (where metadata ? 'session_id') affected_sessions, max(created_at) last_seen
      from public.orderdesk_monitoring_events where event_type <> 'web_vital' and created_at >= now()-interval '7 days'
      group by fingerprint,message,source,page_path order by count(*) desc limit 5
    ) t),'[]'::jsonb),
    'vitals', coalesce((select jsonb_agg(to_jsonb(v)) from (
      select metric_name, round(avg(metric_value)::numeric,2) average, round(percentile_cont(.75) within group(order by metric_value)::numeric,2) p75,
        count(*) samples, count(*) filter(where metric_rating='poor') poor
      from public.orderdesk_monitoring_events where event_type='web_vital' and created_at >= now()-interval '24 hours' and metric_name is not null
      group by metric_name order by metric_name
    ) v),'[]'::jsonb)
  ) into result from public.orderdesk_monitoring_events;
  return result;
end; $$;

create or replace function public.owner_list_monitoring_events(p_filter text default 'all', p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare result jsonb;
begin
  if coalesce(public.owner_is_admin(), false) is not true then raise exception 'Not authorised'; end if;
  select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at desc),'[]'::jsonb) into result
  from (select id,event_type,severity,source,page_path,message,stack,fingerprint,user_agent,metric_name,metric_value,metric_rating,metadata,created_at,resolved_at
    from public.orderdesk_monitoring_events
    where (p_filter='all' or (p_filter='open' and resolved_at is null) or (p_filter='resolved' and resolved_at is not null) or event_type=p_filter)
    order by created_at desc limit greatest(1,least(coalesce(p_limit,100),250))) e;
  return result;
end; $$;

create or replace function public.owner_resolve_monitoring_event(p_id uuid, p_resolved boolean default true)
returns boolean language plpgsql security definer set search_path = public, auth as $$
begin
  if coalesce(public.owner_is_admin(), false) is not true then raise exception 'Not authorised'; end if;
  update public.orderdesk_monitoring_events set resolved_at=case when p_resolved then now() else null end,
    resolved_by=case when p_resolved then auth.uid() else null end where id=p_id;
  return found;
end; $$;

revoke all on function public.owner_monitoring_overview() from public, anon;
revoke all on function public.owner_list_monitoring_events(text,integer) from public, anon;
revoke all on function public.owner_resolve_monitoring_event(uuid,boolean) from public, anon;
grant execute on function public.owner_monitoring_overview() to authenticated;
grant execute on function public.owner_list_monitoring_events(text,integer) to authenticated;
grant execute on function public.owner_resolve_monitoring_event(uuid,boolean) to authenticated;
