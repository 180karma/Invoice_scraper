-- Invoice Scraper: Supabase schema
-- Paste the whole file into Supabase Dashboard > SQL Editor > New query, then Run.
-- Safe to run more than once.
--
-- Shared kitchen library: all signed-in staff sync the same rows.
-- user_id on data tables is the kitchen library id from app_meta (not each person's auth uid).
-- Row-level security: any authenticated user may read/write the kitchen library only.
-- updated_at is set by the app from its local edit time, so devices merge newest-wins.
-- deleted = true is a tombstone: it tells other devices a row was removed.

-- app_meta: kitchen-wide settings (library id). Authenticated users may read; only SQL/admin writes.
create table if not exists public.app_meta (
  key   text primary key,
  value text not null
);
insert into public.app_meta (key, value)
values ('library_user_id', gen_random_uuid()::text)
on conflict (key) do nothing;

alter table public.app_meta enable row level security;
drop policy if exists "app_meta read" on public.app_meta;
create policy "app_meta read" on public.app_meta for select to authenticated using (true);
revoke all on public.app_meta from anon;
grant select on public.app_meta to authenticated;

-- suppliers: one row per supplier (ABN, or the normalised name when there is no ABN), with contacts
create table if not exists public.suppliers (
  user_id           uuid not null,
  supplier_id       text not null,
  name              text not null default '',
  abn               text not null default '',
  phone             text not null default '',
  email             text not null default '',
  website           text not null default '',
  invoice_count     integer not null default 0,
  total_invoiced    numeric,
  last_invoice_date date,
  deleted           boolean not null default false,
  updated_at        timestamptz not null default now(),
  primary key (user_id, supplier_id)
);

-- supplier layouts (templates): zones, header fingerprint and logo; data holds the whole layout
create table if not exists public.layouts (
  user_id     uuid not null,
  id          text not null,
  name        text not null default '',
  abn         text not null default '',
  supplier_id text not null default '',
  auto        boolean not null default false,
  data        jsonb not null default '{}'::jsonb,
  deleted     boolean not null default false,
  updated_at  timestamptz not null default now(),
  primary key (user_id, id)
);

-- invoices: header fields, total, and the file name and folder it was saved under (not the file itself)
create table if not exists public.invoices (
  user_id      uuid not null,
  key          text not null,
  supplier_id  text not null default '',
  supplier     text not null default '',
  abn          text not null default '',
  invoice_no   text not null default '',
  invoice_date date,
  total        numeric,
  line_count   integer not null default 0,
  file_name    text not null default '',
  file_folder  text not null default '',
  src          text not null default 'text',
  phone        text not null default '',
  email        text not null default '',
  website      text not null default '',
  added_at     timestamptz,
  deleted      boolean not null default false,
  updated_at   timestamptz not null default now(),
  primary key (user_id, key)
);

-- line items: one row per invoice line. item_key + uom_key give one price series per item and unit
-- (uom_key folds spellings of one unit together: ea/each, kg/kgs; each vs carton stay apart)
create table if not exists public.line_items (
  user_id      uuid not null,
  invoice_key  text not null,
  line_no      integer not null,
  supplier_id  text not null default '',
  item_key     text not null default '',
  item_no      text,
  description  text,
  quantity     numeric,
  uom          text,
  uom_key      text not null default '',
  weight       numeric,
  unit_price   numeric,
  discount     numeric,
  gst          numeric,
  amount       numeric,
  invoice_date date,
  data         jsonb not null default '{}'::jsonb,
  updated_at   timestamptz not null default now(),
  primary key (user_id, invoice_key, line_no),
  foreign key (user_id, invoice_key) references public.invoices (user_id, key) on delete cascade
);
create index if not exists line_items_series_idx on public.line_items (user_id, item_key, uom_key, invoice_date);

-- ignored items (skipped on new scans) and items hidden from the library
create table if not exists public.ignored_items (
  user_id    uuid not null,
  kind       text not null check (kind in ('ignore', 'hide')),
  item_key   text not null,
  deleted    boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (user_id, kind, item_key)
);

-- settings that are safe to share between devices. API keys are never stored here.
create table if not exists public.settings (
  user_id    uuid not null,
  name       text not null default 'app',
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (user_id, name)
);

-- Existing projects: drop auth.users FKs so deleting a staff account cannot wipe the kitchen library
do $$
declare r record;
begin
  for r in
    select c.conname, c.conrelid::regclass as tbl
    from pg_constraint c
    join pg_class own on own.oid = c.conrelid
    join pg_namespace n on n.oid = own.relnamespace and n.nspname = 'public'
    where c.contype = 'f'
      and own.relname in ('suppliers', 'layouts', 'invoices', 'line_items', 'ignored_items', 'settings')
      and c.confrelid = 'auth.users'::regclass
  loop
    execute format('alter table %s drop constraint if exists %I', r.tbl, r.conname);
  end loop;
end $$;

-- Drop column defaults that still point at auth.uid() (personal account)
alter table public.suppliers alter column user_id drop default;
alter table public.layouts alter column user_id drop default;
alter table public.invoices alter column user_id drop default;
alter table public.line_items alter column user_id drop default;
alter table public.ignored_items alter column user_id drop default;
alter table public.settings alter column user_id drop default;

-- Move any old personal rows into the shared kitchen library (no-op when empty / already shared)
do $$
declare lib uuid;
begin
  select value::uuid into lib from public.app_meta where key = 'library_user_id';
  if lib is null then return; end if;
  update public.suppliers set user_id = lib where user_id is distinct from lib;
  update public.layouts set user_id = lib where user_id is distinct from lib;
  update public.invoices set user_id = lib where user_id is distinct from lib;
  update public.line_items set user_id = lib where user_id is distinct from lib;
  update public.ignored_items set user_id = lib where user_id is distinct from lib;
  update public.settings set user_id = lib where user_id is distinct from lib;
exception
  when others then
    -- skip if a PK clash would occur (two users already have the same invoice key); resolve manually
    raise notice 'Could not auto-merge personal rows into the kitchen library: %', sqlerrm;
end $$;

-- price history view: every purchase of one item in one unit, oldest first
create or replace view public.price_history with (security_invoker = true) as
  select l.user_id, l.supplier_id, l.item_key, l.uom_key, l.item_no, l.description, l.uom,
         l.invoice_date, i.invoice_no, l.quantity, l.unit_price, l.amount
  from public.line_items l
  join public.invoices i on i.user_id = l.user_id and i.key = l.invoice_key and not i.deleted
  order by l.item_key, l.uom_key, l.invoice_date;

-- row-level security: any signed-in staff member may use the kitchen library
do $$
declare t text;
begin
  foreach t in array array['suppliers', 'layouts', 'invoices', 'line_items', 'ignored_items', 'settings'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "own rows select" on public.%I', t);
    execute format('drop policy if exists "own rows insert" on public.%I', t);
    execute format('drop policy if exists "own rows update" on public.%I', t);
    execute format('drop policy if exists "own rows delete" on public.%I', t);
    execute format('drop policy if exists "kitchen library select" on public.%I', t);
    execute format('drop policy if exists "kitchen library insert" on public.%I', t);
    execute format('drop policy if exists "kitchen library update" on public.%I', t);
    execute format('drop policy if exists "kitchen library delete" on public.%I', t);
    execute format(
      'create policy "kitchen library select" on public.%I for select to authenticated using (user_id = (select value::uuid from public.app_meta where key = ''library_user_id''))',
      t);
    execute format(
      'create policy "kitchen library insert" on public.%I for insert to authenticated with check (user_id = (select value::uuid from public.app_meta where key = ''library_user_id''))',
      t);
    execute format(
      'create policy "kitchen library update" on public.%I for update to authenticated using (user_id = (select value::uuid from public.app_meta where key = ''library_user_id'')) with check (user_id = (select value::uuid from public.app_meta where key = ''library_user_id''))',
      t);
    execute format(
      'create policy "kitchen library delete" on public.%I for delete to authenticated using (user_id = (select value::uuid from public.app_meta where key = ''library_user_id''))',
      t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;
revoke all on public.price_history from anon;
grant select on public.price_history to authenticated;
