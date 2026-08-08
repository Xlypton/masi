-- SEC-2: take `anon` off the C-5d and deletion-approval RPCs.
--
-- Follow-up to 2026-08-08_sec1_revoke_internal_helper_execute.sql, which
-- established the fact this depends on: `REVOKE ALL ... FROM public` does NOT
-- remove Supabase's default-privilege grant made directly to the `anon` and
-- `authenticated` roles. Those are real roles, not members reached through the
-- PUBLIC pseudo-role. Every function below was written with a bare
-- `REVOKE ... FROM public`, which stripped the PUBLIC entry and left `anon=X`
-- sitting there - visible in `pg_proc.proacl`, and exactly the gap SEC-1 found.
--
-- THIS IS NOT SEC-1. Measured on live before applying: all five functions below
-- already REFUSE an anonymous caller, because unlike `topo_snapshot` and
-- friends they each carry their own guard as their first statement -
-- `IF actor IS NULL ...` or `IF ... NOT public.is_admin() THEN RAISE EXCEPTION
-- '42501'`. Nothing was readable or writable by anon through them. SEC-1 was an
-- open door; this is a door that was locked but should not have been reachable.
--
-- It is worth closing anyway, for one reason that is not tidiness: the guard is
-- the ONLY thing standing between anon and these functions, so any future edit
-- that moves, weakens or short-circuits that first `IF` silently turns a
-- defence-in-depth gap into SEC-1 again. Removing the grant means the guard is
-- the second line rather than the only one.
--
-- `authenticated` KEEPS EXECUTE on the five RPCs the app actually calls, and
-- loses it on the two pure helpers, which no client has any business calling:
-- `material_change_kinds` and `merge_change_kinds` exist only to be called by
-- `note_material_change`, which runs as the table owner and is unaffected by
-- these ACLs.
--
-- REVOKE is naturally idempotent, so this is safe to re-run.

-- The RPCs the client calls: anon out, authenticated back in.
REVOKE ALL ON FUNCTION public.material_changes(int)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.material_changes(int) TO authenticated;

REVOKE ALL ON FUNCTION public.resolve_material_change(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_material_change(text) TO authenticated;

REVOKE ALL ON FUNCTION public.request_deletion(text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.request_deletion(text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.review_deletion(text, boolean, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.review_deletion(text, boolean, text) TO authenticated;

REVOKE ALL ON FUNCTION public.deletion_requests_queue(int)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.deletion_requests_queue(int) TO authenticated;

-- Internal helpers: no client role at all. Both are IMMUTABLE and side-effect
-- free, so nothing was at risk - but neither has a caller check either, which
-- puts them in SEC-1's category rather than this one, and the rule there is
-- that a SECURITY DEFINER-adjacent helper with no guard must be revoked.
REVOKE ALL ON FUNCTION public.material_change_kinds(jsonb, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.merge_change_kinds(jsonb, jsonb)
  FROM PUBLIC, anon, authenticated;
