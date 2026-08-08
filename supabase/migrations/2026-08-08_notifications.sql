-- An inbox: the things other people did to your work.
--
-- Until now the app told you nothing. Somebody commented on your topo, tagged
-- you, liked your ascent or proposed a line, and the only way to find out was
-- to go and look. This adds the record of those events. The IN-APP centre is
-- what ships; real push (VAPID keys, a service-worker handler, an edge
-- function) is deliberately out of scope, and the shape below is chosen so it
-- can be added later without moving anything: a notification is a ROW that
-- already exists by the time a push would be sent, so a future sender reads
-- this table rather than replacing it.
--
-- ---------------------------------------------------------------------------
-- THE SECURITY PROPERTY, stated first because everything else follows from it
-- ---------------------------------------------------------------------------
--
-- A client can never author a notification. There is NO insert policy on this
-- table and no RPC that writes one; every row comes from a SECURITY DEFINER
-- trigger fired by an action the server already witnessed. That is not
-- tidiness. A client that could insert here could put any sentence it liked in
-- anybody else's inbox, attributed to anybody it liked — the most convincing
-- phishing surface the app could possibly have, and one that would arrive
-- pre-trusted because it renders in the user's own notification centre.
--
-- Marking read goes through an RPC rather than an UPDATE policy for a reason
-- worth writing down: RLS can restrict WHICH ROWS an update touches, but not
-- WHICH COLUMNS. A `USING ("recipientId" = auth.uid())` update policy would
-- let a recipient rewrite `kind`, `actorId` and `preview` on their own rows —
-- harmless to others, but it turns their own inbox into free-form storage and
-- makes the table's contents no longer trustworthy as a record of what
-- happened. `mark_notifications_read` writes exactly one column.
--
-- ---------------------------------------------------------------------------
-- WHY THE TRIGGERS ARE SHAPED THE WAY THEY ARE
-- ---------------------------------------------------------------------------
--
-- The sync engine has no outbox (decision D-4): it re-reads and re-sends the
-- client's own rows on every push. So `comments` and `likes` receive an UPDATE
-- for every row the user owns, over and over, forever. A naive
-- `AFTER INSERT OR UPDATE` trigger would therefore re-notify on every sync,
-- and the FIRST sync after this migration would deliver a notification for
-- every comment and like that has ever existed.
--
-- Two things prevent that, and both are needed:
--
--   * each branch fires only on a real TRANSITION — a comment is new, a
--     comment's mention list actually changed, a like went from tombstoned to
--     active. An unchanged re-push transitions nothing and fires nothing.
--   * every notification id is DERIVED from the event that caused it
--     (`l:<likeId>`, `c:<commentId>`, `m:<commentId>:<uid>`, `s:<suggestionId>`)
--     and inserted `ON CONFLICT DO NOTHING`. This is what answers the
--     like/unlike/like case: `LikesRepository._toggle` flips `deletedAt` on the
--     SAME row rather than inserting a new one, so all three taps derive the
--     same id and the owner is told once. A dedup table or a time window would
--     both have been guesses; the row identity is a fact.
--
-- The trigger functions swallow their own errors. A notification is a
-- courtesy; a comment is the user's data. If anything in here raises — a
-- malformed `mentionedUids` payload, a future column change — the enclosing
-- INSERT must still commit, because the alternative is that a bug in this file
-- silently breaks every sync push in the app.

-- ---------------------------------------------------------------------------
-- 1. The table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.notifications (
  id            text PRIMARY KEY,
  "recipientId" text   NOT NULL,
  -- The raw event name. Deliberately `text` and not an enum: the client parses
  -- it at the edge and renders an unknown value as a generic entry, so adding
  -- a kind never needs a coordinated client release, and a build that predates
  -- one does not crash on it.
  kind          text   NOT NULL,
  "actorId"     text,
  "wallId"      text,
  "ascentId"    text,
  "commentId"   text,
  -- A short server-rendered summary — the comment's first line, or the topo's
  -- name. Not required: a row reads perfectly well without one.
  preview       text,
  "createdAt"   bigint NOT NULL,
  -- A timestamp, not a bool, so "mark all read" is one write with one value
  -- and the unread badge is a plain `readAt IS NULL` count.
  "readAt"      bigint
);

-- The only query this table has: my inbox, newest first.
CREATE INDEX IF NOT EXISTS notifications_recipient_created
  ON public.notifications ("recipientId", "createdAt" DESC);

-- The badge. Partial, because the unread set is the small one and stays small
-- if the feature works.
CREATE INDEX IF NOT EXISTS notifications_recipient_unread
  ON public.notifications ("recipientId") WHERE "readAt" IS NULL;

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- Read: the recipient, and nobody else. Not even an admin — an inbox is not
-- moderation material, and `moderation_log` already records every action a
-- moderator might need to look back at.
DROP POLICY IF EXISTS notifications_read ON public.notifications;
CREATE POLICY notifications_read
  ON public.notifications
  FOR SELECT TO authenticated
  USING ("recipientId" = (auth.uid())::text);

-- REVOKE ALL first, then grant back exactly one privilege to exactly one role.
--
-- The blanket revoke is not belt-and-braces. Supabase's default privileges
-- `GRANT ALL ON TABLES TO anon, authenticated`, so a freshly created table
-- arrives with INSERT, UPDATE, DELETE, **TRUNCATE**, REFERENCES and TRIGGER
-- already handed to both client roles, and a targeted
-- `REVOKE INSERT, UPDATE, DELETE` — which is what this file did on its first
-- pass — leaves TRUNCATE sitting there. That one matters more than the rest
-- put together: **TRUNCATE is not filtered by RLS**, so the recipient-only
-- SELECT policy above would not have stopped any signed-in client from
-- emptying every inbox in the project in one statement.
--
-- Same fact as SEC-1/SEC-2 in a different costume: `anon` and `authenticated`
-- are real roles holding their own grants, not members reached through PUBLIC,
-- so nothing you revoke from PUBLIC touches them.
REVOKE ALL ON public.notifications FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.notifications TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. The writer
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.push_notification(text, text, text, text, text, text, text, bigint);

-- The single place a notification row is created. Every trigger below funnels
-- through it so the "never notify yourself" rule and the derived-id dedup
-- exist once rather than four times.
--
-- Returns nothing and raises nothing: a caller that supplies a null recipient,
-- or names the actor as the recipient, gets silence rather than an error. Both
-- are ordinary — a topo with no owner recorded, or somebody commenting on
-- their own topo — and neither is worth failing a write over.
CREATE OR REPLACE FUNCTION public.push_notification(
  notification_id text,
  recipient       text,
  kind            text,
  actor           text,
  wall_id         text,
  ascent_id       text,
  comment_id      text,
  preview         text,
  created_at      bigint
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  IF recipient IS NULL OR recipient = '' THEN RETURN; END IF;
  -- NEVER notify somebody about their own action. Liking your own topo, or
  -- answering your own comment thread, is not news.
  IF actor IS NOT NULL AND actor = recipient THEN RETURN; END IF;

  INSERT INTO public.notifications
    (id, "recipientId", kind, "actorId", "wallId", "ascentId", "commentId",
     preview, "createdAt")
  VALUES
    (notification_id, recipient, kind, actor, wall_id, ascent_id, comment_id,
     -- Bounded here rather than at the call sites: a preview is a glance, and
     -- an unbounded one would put an entire comment in every inbox row.
     left(preview, 140), created_at)
  ON CONFLICT (id) DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION public.push_notification(text, text, text, text, text, text, text, text, bigint)
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Comments — and mentions
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.notify_on_comment()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  owner     text;
  wall      text;
  mentions  jsonb;
  mentioned text;
  is_new    boolean := TG_OP = 'INSERT';
  changed   boolean;
BEGIN
  -- A tombstoned comment notifies nobody. Deleting is also how the client
  -- represents "I took that back", and a notification is exactly the thing
  -- that must not survive it.
  IF NEW."deletedAt" IS NOT NULL THEN RETURN NEW; END IF;

  changed := is_new OR NEW."mentionedUids" IS DISTINCT FROM OLD."mentionedUids";
  IF NOT is_new AND NOT changed THEN RETURN NEW; END IF;

  -- Who this comment is attached to, and what to call it. An ascent comment
  -- carries the ascent's wall too, so the row can say WHICH topo the ascent
  -- was on without the client having to resolve it.
  IF NEW."ascentId" IS NOT NULL THEN
    SELECT a."ownerId", a."wallId" INTO owner, wall
      FROM public.ascents a
     WHERE a.id = NEW."ascentId" AND a."deletedAt" IS NULL;
  ELSIF NEW."wallId" IS NOT NULL THEN
    SELECT w."ownerId", w.id INTO owner, wall
      FROM public.walls w
     WHERE w.id = NEW."wallId" AND w."deletedAt" IS NULL;
  END IF;

  mentions := CASE
    WHEN NEW."mentionedUids" IS NULL THEN NULL
    ELSE NEW."mentionedUids"::jsonb
  END;

  -- A MENTION SUPERSEDES the ownership notification. Being tagged is the more
  -- specific fact and the more urgent one, and an owner who is also tagged
  -- getting two rows for one comment reads as a bug in the inbox rather than
  -- as thoroughness.
  IF is_new AND NOT (
    mentions IS NOT NULL
    AND owner IS NOT NULL
    AND mentions ? owner
  ) THEN
    PERFORM public.push_notification(
      'c:' || NEW.id, owner, 'comment', NEW."ownerId",
      wall, NEW."ascentId", NEW.id, NEW.body, NEW."createdAt");
  END IF;

  IF mentions IS NOT NULL AND jsonb_typeof(mentions) = 'array' THEN
    FOR mentioned IN SELECT jsonb_array_elements_text(mentions) LOOP
      PERFORM public.push_notification(
        'm:' || NEW.id || ':' || mentioned, mentioned, 'mention', NEW."ownerId",
        wall, NEW."ascentId", NEW.id, NEW.body, NEW."createdAt");
    END LOOP;
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- See this file's header: the comment is the user's data, the notification
  -- is a courtesy. Never let the second cost them the first.
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_on_comment() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS notify_on_comment ON public.comments;
CREATE TRIGGER notify_on_comment
  AFTER INSERT OR UPDATE ON public.comments
  FOR EACH ROW EXECUTE FUNCTION public.notify_on_comment();

-- ---------------------------------------------------------------------------
-- 4. Likes
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.notify_on_like()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  owner     text;
  wall      text;
  topo_name text;
BEGIN
  -- Only the moment a like BECOMES active. On insert that is the first tap; on
  -- update it is a re-like of a tombstoned row. An ordinary full-state re-push
  -- (D-4) changes neither and lands here doing nothing at all, which is the
  -- whole reason this condition is written as a transition rather than as a
  -- state test.
  IF NEW."deletedAt" IS NOT NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD."deletedAt" IS NULL THEN RETURN NEW; END IF;

  IF NEW."ascentId" IS NOT NULL THEN
    SELECT a."ownerId", a."wallId" INTO owner, wall
      FROM public.ascents a
     WHERE a.id = NEW."ascentId" AND a."deletedAt" IS NULL;
  ELSIF NEW."wallId" IS NOT NULL THEN
    SELECT w."ownerId", w.id INTO owner, wall
      FROM public.walls w
     WHERE w.id = NEW."wallId" AND w."deletedAt" IS NULL;
  END IF;

  SELECT w.name INTO topo_name FROM public.walls w WHERE w.id = wall;

  -- `l:<likeId>`, not `l:<actor>:<target>`: the row id already IS the identity
  -- of "this person's like of this thing" (the toggle flips `deletedAt` in
  -- place), so deriving from it dedups like/unlike/like for free and needs no
  -- assumption about how the client builds its keys.
  PERFORM public.push_notification(
    'l:' || NEW.id, owner, 'like', NEW."ownerId",
    wall, NEW."ascentId", NULL, topo_name, NEW."createdAt");

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_on_like() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS notify_on_like ON public.likes;
CREATE TRIGGER notify_on_like
  AFTER INSERT OR UPDATE ON public.likes
  FOR EACH ROW EXECUTE FUNCTION public.notify_on_like();

-- ---------------------------------------------------------------------------
-- 5. Suggested edits
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.notify_on_suggestion()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  owner     text;
  topo_name text;
BEGIN
  -- INSERT only. `topo_edit_suggestions` is server-written through
  -- `suggest_edit` and is not part of the client's re-push, so there is no
  -- repeat-UPDATE problem here — and a suggestion being RESOLVED updates the
  -- same row, which must not read as a second suggestion arriving.
  SELECT w."ownerId", w.name INTO owner, topo_name
    FROM public.walls w
   WHERE w.id = NEW."wallId" AND w."deletedAt" IS NULL;

  PERFORM public.push_notification(
    's:' || NEW.id, owner, 'suggestion', NEW."authorId",
    NEW."wallId", NULL, NULL, topo_name, NEW."createdAt");

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_on_suggestion() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS notify_on_suggestion ON public.topo_edit_suggestions;
CREATE TRIGGER notify_on_suggestion
  AFTER INSERT ON public.topo_edit_suggestions
  FOR EACH ROW EXECUTE FUNCTION public.notify_on_suggestion();

-- ---------------------------------------------------------------------------
-- 6. Reading the inbox
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.my_notifications(int);

-- Newest first, unlike every admin queue in this project. Those are work
-- lists, where the number that matters is how long somebody has been kept
-- waiting; this is an inbox, where it is what just happened.
CREATE OR REPLACE FUNCTION public.my_notifications(limit_count int DEFAULT 50)
RETURNS TABLE (
  "id"          text,
  "recipientId" text,
  "kind"        text,
  "actorId"     text,
  "actorName"   text,
  "wallId"      text,
  "ascentId"    text,
  "commentId"   text,
  "preview"     text,
  "createdAt"   bigint,
  "readAt"      bigint
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  me text := (auth.uid())::text;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  limit_count := greatest(1, least(coalesce(limit_count, 50), 200));

  RETURN QUERY
  -- The actor's name comes down with the row. The client would otherwise have
  -- to resolve a uid it may well have no profile for — a notification arrives
  -- precisely BECAUSE somebody you may not know did something — and the one
  -- thing this screen must never render is a raw uid.
  SELECT n.id, n."recipientId", n.kind, n."actorId", p."displayName",
         n."wallId", n."ascentId", n."commentId", n.preview,
         n."createdAt", n."readAt"
    FROM public.notifications n
    LEFT JOIN public.profiles p ON p.id = n."actorId"
   WHERE n."recipientId" = me
   ORDER BY n."createdAt" DESC
   LIMIT limit_count;
END;
$$;

REVOKE ALL ON FUNCTION public.my_notifications(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.my_notifications(int) TO authenticated;

DROP FUNCTION IF EXISTS public.unread_notification_count();

CREATE OR REPLACE FUNCTION public.unread_notification_count()
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  me text := (auth.uid())::text;
  n  int;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;
  SELECT count(*) INTO n FROM public.notifications
   WHERE "recipientId" = me AND "readAt" IS NULL;
  RETURN n;
END;
$$;

REVOKE ALL ON FUNCTION public.unread_notification_count() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.unread_notification_count() TO authenticated;

DROP FUNCTION IF EXISTS public.mark_notifications_read(text[]);

-- Marks [ids] read, or the caller's whole unread set when [ids] is NULL.
--
-- Scoped to the caller in the WHERE clause and not merely trusted to RLS: this
-- runs SECURITY DEFINER, so RLS does not apply to it at all, and the predicate
-- below is the ONLY thing standing between a caller and somebody else's rows.
--
-- Only ever writes `readAt`, and only ever from NULL — re-marking something
-- already read leaves the original instant alone, so "read at" stays the truth
-- rather than becoming "last tapped at".
CREATE OR REPLACE FUNCTION public.mark_notifications_read(ids text[] DEFAULT NULL)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  now_ms bigint := (extract(epoch FROM now()) * 1000)::bigint;
  me     text   := (auth.uid())::text;
  n      int;
BEGIN
  IF me IS NULL THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  UPDATE public.notifications
     SET "readAt" = now_ms
   WHERE "recipientId" = me
     AND "readAt" IS NULL
     AND (ids IS NULL OR id = ANY (ids));

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_notifications_read(text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_notifications_read(text[]) TO authenticated;
