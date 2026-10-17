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
| `public/favicon.ico` | Legacy tab icon, bookmarks, Windows | 16 + 32 + 48 px, tight crop |
| `public/icon.svg` | Modern tab icon (`type="image/svg+xml"`), manifest `sizes="any"` | Tight crop, transparent |
| `public/icon.png` / `public/icon-192.png` | Manifest `purpose: any` (512 / 192) | Transparent, padded |
| `public/icon-maskable-512.png` | Manifest `purpose: maskable` — Android adaptive icons, which crop to a circle / squircle | Opaque, mark inside the safe zone |
| `public/apple-touch-icon.png` | iOS home screen (180 px) | Opaque — iOS paints black behind transparency |

The exact crops, and why each is what it is, are comments beside the constants
in `bin/build-icons`.

The `<head>` in [`app/views/layouts/application.html.erb`](../../app/views/layouts/application.html.erb)
links the ICO, the SVG, the Apple touch icon and the manifest, and declares a
`theme-color` per colour scheme — the tenant's navbar colour when one is set,
else `Tenant::DEFAULT_NAV_BG_COLOR` / `_DARK` (`Tenant.browser_theme_color`).
A view can replace both with `content_for(:theme_color, …)`; the sign-in page
does, with Bento's sloe (`#6b58da`) in both schemes, since it has no navbar.
The manifest is a static [`public/manifest.json`](../../public/manifest.json)
(nothing in it is per-request, so it costs no Rails request); its `theme_color`
is the app default — an installed app's splash and title bar are therefore
GrowthOS teal even for a themed tenant, a known trade-off of keeping it static.
It lists only PNGs: Chromium's manifest icon fetcher has no SVG decoder, so an
SVG entry it selects yields a blank tile. The service worker is deliberately not enabled (nothing
needs offline or push yet).

**The links are versioned.** Production serves `public/` with a one-year
`cache-control`, so the layout links every icon and the manifest through
`AppIconsHelper#app_icon_path`, which appends `?v=<digest of the icon files>`
— regenerate the set and every returning browser refetches it. Two things it
cannot reach: a browser's own unsolicited `GET /favicon.ico`, and the icon
URLs inside the manifest (installed home-screen tiles refresh on the
platform's own schedule regardless).

**Three places must agree on the brand teal**: the `--color-primary` /
`--color-nav-bg` tokens in `application.css`, `Tenant::DEFAULT_NAV_BG_COLOR`,
and `COLOR` in `bin/build-icons`. `test/integration/app_icons_test.rb` pins the
last two to each other and to the manifest.

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
first.

## Changing the mark

Edit the `STEPS` / `LEAF` path data (and `COLOR`) in `bin/build-icons`, then
regenerate. Keep the mark's bounding box centred at (531.5, 513.5) in the
1024 box, or update `CX` / `CY` — every crop is computed from that centre.

The sign-in page draws the mark inline, in the text colour rather than teal, so
it follows light and dark mode
(`Views::Users::Sessions::NewView::MARK_PATHS`). Those paths are a copy of
`STEPS` / `LEAF`: change both. `test/integration/app_icons_test.rb` fails when
they differ.
