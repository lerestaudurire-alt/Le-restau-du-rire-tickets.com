-- Mise a jour uniquement (parties 05, 06, 07) : SANS les anciens scripts 00 a 04.
-- A coller dans Supabase > SQL Editor pour une base deja installee.

-- ########## 05-fix-creation-evenement.sql ##########
-- 05 — Correction : "Création impossible (400) : expected JSON array [22P02]"
-- Cause : certaines colonnes de la table events existent déjà dans votre base avec un type
-- tableau (text[]), alors que le site envoie du JSON (objets). Les scripts précédents
-- ("add column if not exists") ne changent jamais le type d'une colonne déjà créée.
-- À exécuter UNE fois dans Supabase > SQL Editor. Sans danger si déjà correct.

-- 0) Supprimer les anciennes contraintes CHECK qui utilisent des fonctions de tableau
--    (ex. cardinality(pay_numbers)) : elles bloquent la conversion en jsonb.
do $$
declare r record;
begin
  for r in select conname from pg_constraint
           where conrelid='public.events'::regclass and contype='c'
             and (pg_get_constraintdef(oid) ilike '%tickets%'
               or pg_get_constraintdef(oid) ilike '%pay_numbers%'
               or pg_get_constraintdef(oid) ilike '%modes%'
               or pg_get_constraintdef(oid) ilike '%cardinality%'
               or pg_get_constraintdef(oid) ilike '%array_length%') loop
    execute format('alter table public.events drop constraint %I', r.conname);
  end loop;
end $$;

do $$
declare c text;
begin
  foreach c in array array['tickets','pay_numbers'] loop
    if exists (select 1 from information_schema.columns
               where table_schema='public' and table_name='events' and column_name=c
                 and (data_type='ARRAY' or data_type in ('text','json','character varying'))) then
      execute format('alter table public.events alter column %I drop default', c);
      execute format('alter table public.events alter column %I type jsonb using
        case when %I is null then ''[]''::jsonb else to_jsonb(%I) end', c, c, c);
    end if;
  end loop;

  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='events' and column_name='modes'
               and data_type<>'jsonb') then
    alter table public.events alter column modes drop default;
    alter table public.events alter column modes type jsonb using '{}'::jsonb;
  end if;
end $$;

-- Valeurs par défaut sûres
alter table public.events alter column tickets set default '[]'::jsonb;
alter table public.events alter column pay_numbers set default '[]'::jsonb;
alter table public.events alter column modes set default '{}'::jsonb;

-- Même vérification pour les commandes (items envoyés en JSON)
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='orders' and column_name='items'
               and data_type<>'jsonb') then
    alter table public.orders alter column items type jsonb using to_jsonb(items);
  end if;
end $$;

notify pgrst, 'reload schema';

-- Contrôle : les 3 lignes doivent afficher "jsonb"

-- ########## 06 : evenements sur plusieurs dates (festival) ##########
alter table public.events add column if not exists ends_at timestamptz;
alter table public.events add column if not exists dates jsonb;
notify pgrst, 'reload schema';

-- ########## 07 : colonnes obligatoires heritees (ex. "cat") qui bloquent la creation ##########
do $$
declare r record;
begin
  for r in select column_name from information_schema.columns
           where table_schema='public' and table_name='events'
             and is_nullable='NO' and column_default is null and column_name<>'id' loop
    execute format('alter table public.events alter column %I drop not null', r.column_name);
  end loop;
end $$;
notify pgrst, 'reload schema';
-- 08 — Page de suivi de l'organisateur (lien #progress/...) : fonction event_progress
-- Ne renvoie AUCUNE donnee personnelle (ni nom, ni telephone) : seulement les chiffres de vente.
drop function if exists public.event_progress(text);
create or replace function public.event_progress(p_token text) returns jsonb
language sql stable security definer set search_path=public as $$
  select coalesce((
    select jsonb_build_object(
      'found', true,
      'title', e.title, 'venue', e.venue, 'city', e.city,
      'starts_at', e.starts_at, 'dates', e.dates,
      'tickets', coalesce(e.tickets,'[]'::jsonb),
      'orders', coalesce((
        select jsonb_agg(jsonb_build_object(
          'status', o.status,
          'kind', o.kind,
          'used', coalesce(o.used,false),
          'items', coalesce(o.items,'[]'::jsonb),
          'qty', coalesce(o.total_qty,(select coalesce(sum((i->>'qty')::int),0) from jsonb_array_elements(coalesce(o.items,'[]'::jsonb)) i)),
          'amounts', coalesce(o.amounts,'{}'::jsonb),
          'day', to_char(o.created_at,'YYYY-MM-DD')))
        from public.orders o
        where o.event_id=e.id and o.status in ('pending','confirmed')), '[]'::jsonb))
    from public.events e
    where coalesce(p_token,'')<>'' and e.share_token=p_token
    limit 1
  ), jsonb_build_object('found', false));
$$;
grant execute on function public.event_progress(text) to anon, authenticated;
notify pgrst, 'reload schema';

-- 09 — Suppression d'un evenement depuis le tableau de bord
-- Admin : peut tout supprimer. Organisateur : seulement ses evenements SANS commande confirmee.
drop function if exists public.delete_event(uuid);
create or replace function public.delete_event(p_id uuid) returns boolean
language plpgsql security definer set search_path=public as $$
declare ev public.events%rowtype;
begin
  select * into ev from public.events where id=p_id;
  if not found then raise exception 'introuvable'; end if;
  if not public.is_admin() then
    if ev.owner_id is distinct from auth.uid() then raise exception 'refuse'; end if;
    if exists(select 1 from public.orders where event_id=p_id and status='confirmed') then
      raise exception 'Cet evenement a deja des billets confirmes : contactez l''administrateur pour le supprimer.';
    end if;
  end if;
  delete from public.orders where event_id=p_id;
  delete from public.events where id=p_id;
  return true;
end $$;
revoke all on function public.delete_event(uuid) from public, anon;
grant execute on function public.delete_event(uuid) to authenticated;
notify pgrst, 'reload schema';
