# Hosting the Masi PWA

The web build (`flutter build web`, wasm by default) requires the page to be
**cross-origin isolated**. Both drift's OPFS worker (`web/drift_worker.js`,
used for the wasm-backed SQLite persistence) and `dart2wasm`'s
`instantiateStreaming` path need this — without it, drift silently falls back
to a slower/less durable storage mode and some wasm loading paths break.

Cross-origin isolation requires two response headers on **every** document
response (not just the wasm file itself):

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

`*.wasm` files also need an explicit `Content-Type: application/wasm` —
some hosts default unknown extensions to `application/octet-stream`, which
some browsers refuse for `instantiateStreaming()`.

Two ready-made configs are provided so either host works out of the box:

- **`web/_headers`** — Cloudflare Pages' header-rules format. `flutter build
  web` copies every non-templated file under `web/` straight into
  `build/web/`, so this lands at `build/web/_headers` automatically — no
  extra copy step needed — and Cloudflare Pages picks up `_headers` from the
  root of the published directory.
- **`firebase.json`** (repo root) — Firebase Hosting config: serves
  `build/web`, SPA-rewrites everything to `/index.html`, and sets the same
  COOP/COEP + `application/wasm` headers. JSON has no comment syntax, hence
  this note living here instead of inline.

If you ever put Masi behind a different static host, port these same
three headers (COOP, COEP, and the wasm content-type) to that host's config
format — that's the whole requirement.
