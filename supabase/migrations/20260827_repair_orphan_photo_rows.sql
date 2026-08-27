-- Repair: reinstate two `photos` rows whose Storage objects exist but whose
-- metadata rows never reached the server.
--
-- ## What was wrong
--
-- Four live routes across two PUBLISHED walls referenced two photo ids with no
-- `photos` row at all (not even a tombstone). Consequences for real viewers:
--
--   * wall 6a7d9681 ("shared", 3 photos, 9 live routes) silently lost 3 of its
--     lines for everyone, because the client drops a shared route whose photo
--     is absent from the batch (`fetchSharedTopos`);
--   * wall a11ea465 ("8", "shared") had ZERO photo rows and one route, so it
--     sat in the community feed and could not render anything at all.
--
-- The Storage objects for both photos exist and always did, so the bytes
-- uploaded and only the metadata row never landed. With no outbox (D-4)
-- nothing revisits a row that was never sent, so this did not and would not
-- self-heal: written 2026-08-22, still broken 2026-08-27, all four routes
-- `dirty = false`.
--
-- The push-side defect that let routes go up ahead of their photo is fixed
-- separately in `routesWithResolvablePhoto` (sync_remote.dart). That stops it
-- recurring; it cannot repair what already shipped.
--
-- ## Why these values are trustworthy
--
-- `width`/`height` are MEASURED from the actual Storage objects (both
-- 4032x3024), not inferred. That distinction matters: the healthy sibling
-- photo on wall 6a7d9681 is 3024x4032 — PORTRAIT — so copying dimensions from
-- a neighbour would have transposed the aspect ratio and misplaced every route
-- line on the topo. A wrong geometry is worse than a missing photo.
--
-- `createdAt`/`updatedAt` are the Storage objects' own creation timestamps,
-- which makes this repair SAFE AGAINST THE OWNER'S DEVICE. That device may
-- still hold the true rows; if it ever pushes them they will carry a newer
-- `updatedAt` and win last-writer-wins outright, replacing these. Likewise a
-- pull cannot clobber the device's copy, since `_shouldWriteLww` keeps the
-- newer local row. This fills a gap; it cannot overwrite the truth.
--
-- `ON CONFLICT DO NOTHING` for the same reason: if the rows have landed by the
-- time this runs, it is a no-op rather than a regression.
--
-- `isPrimary` is true only for wall a11ea465, which has no other photo and
-- therefore no primary; wall 6a7d9681 already has one and must keep it.

INSERT INTO public.photos (
  id, "createdAt", "updatedAt", "deletedAt", "remoteId", dirty, "ownerId",
  "wallId", "localPath", kind, width, height, "parentPhotoId",
  "cropXpct", "cropWidthPct", "sortOrder", "isPrimary"
) VALUES
  (
    'fb693028-b7cc-42e8-9244-fdbcaa0197f8',
    1787421328123, 1787421328123, NULL, NULL, false,
    'ff625054-4522-4786-8cd2-f54c11ec2620',
    '6a7d9681-6875-4628-af05-525fe5fcdc35',
    'photos/fb693028-b7cc-42e8-9244-fdbcaa0197f8.jpg',
    'original', 4032, 3024, NULL, NULL, NULL,
    3,      -- max(sortOrder) on this wall is 2
    false   -- 1e026fbf is already this wall's primary
  ),
  (
    '0c988291-1b33-4b69-a417-b235ca4c4ca5',
    1787482813265, 1787482813265, NULL, NULL, false,
    'ff625054-4522-4786-8cd2-f54c11ec2620',
    'a11ea465-238c-41e2-bd1e-bfa34b4f08fd',
    'photos/0c988291-1b33-4b69-a417-b235ca4c4ca5.jpeg',
    'original', 4032, 3024, NULL, NULL, NULL,
    0,
    true    -- the only photo on this wall, which currently has none
  )
ON CONFLICT (id) DO NOTHING;
