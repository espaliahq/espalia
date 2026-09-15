# App Icons

> Read this when: changing the favicon, the home-screen / installed-app icon,
> the web app manifest, or the brand mark itself.

## The mark

GrowthOS's mark is three ascending steps with a leaf sprouting from the top
step — a career path, and the growth it produces. It is a **vector**: the two
paths in [`bin/build-icons`](../../bin/build-icons) are the source of truth,
and [`public/icon.svg`](../../public/icon.svg) is written from them (with a
`<title>`/`<desc>` so the SVG is self-describing wherever it is embedded).
The fill is `--color-primary` (`#32c8c8`), the same token the navbar uses, so
the tab icon and the chrome beside it agree.

## The asset set

Every file is generated — never hand-edit a PNG.

| File | Used by | Shape |
|---|---|---|
| `public/favicon.ico` | Legacy tab icon, bookmarks, Windows | 16 + 32 + 48 px, tight crop (~4% padding) so the small sizes spend their pixels on the mark |
| `public/icon.svg` | Modern tab icon (`type="image/svg+xml"`), manifest `sizes="any"` | Same tight crop, transparent |
| `public/icon.png` / `public/icon-192.png` | Manifest `purpose: any` (512 / 192) | Transparent, ~10% padding |
| `public/icon-maskable-512.png` | Manifest `purpose: maskable` — Android adaptive icons, which crop to a circle / squircle | Opaque white, mark inside the 80% safe zone |
| `public/apple-touch-icon.png` | iOS home screen (180 px) | Opaque white — iOS paints black behind transparency |

The `<head>` in [`app/views/layouts/application.html.erb`](../../app/views/layouts/application.html.erb)
links the ICO, the SVG, the Apple touch icon and the manifest, and declares a
`theme-color` per colour scheme (`--color-nav-bg` light / dark). The manifest
lives at [`app/views/pwa/manifest.json.erb`](../../app/views/pwa/manifest.json.erb)
and is served by Rails' built-in `rails/pwa#manifest`; the service worker is
deliberately not enabled (nothing needs offline or push yet).

## Regenerating

The generator needs two npm packages (`@resvg/resvg-js` for rasterising,
`png-to-ico` for the ICO container). Install them outside the tree so the
repo stays Node-free:

```bash
npm install --no-save --prefix tmp/icon-build @resvg/resvg-js png-to-ico
NODE_PATH=tmp/icon-build/node_modules bin/build-icons
```

Then eyeball the outputs (`Read` the PNGs, or open them from the IDE) — in
particular the 16 px face of the ICO, which is where a mark stops reading
first. `test/integration/app_icons_test.rb` pins the head links, the manifest,
and that every referenced file exists.

## Changing the mark

Edit the `STEPS` / `LEAF` path data (and `COLOR`) in `bin/build-icons`, then
regenerate. Keep the mark's bounding box centred at (531.5, 513.5) in the
1024 box, or update `CX` / `CY` — every crop is computed from that centre.
