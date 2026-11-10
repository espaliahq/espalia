# README screenshots

The images the top-level [README](../../README.md) shows. To retake or add one
so it matches the set:

- **Seeded data only.** Run `bin/setup`. Calibration needs
  `bin/rails assessments:seed_calibration_activity` too: it closes the open
  cycle, opens two more and leaves a live session to open.
- **Sign in as someone with a person record.** The seeded admin has none, so
  its Feedback page is empty. `marisol@nullisland.example` is a manager with
  feedback on her reports. Logins are in the README's *Getting started*.
- **1440×900 at 2× pixel ratio, light scheme.** In the Chrome MCP:
  `emulate(viewport: "1440x900x2", colorScheme: "light")`.
- **The set uses a Custom theme, not Default.** Under *Tenant admin → Theme*,
  pick Custom with navbar `#2b2640` and brand `#a83265`. Put it back to
  Default afterwards.
- **Quantise before committing.** `pngquant --quality=80-95 --strip` takes a
  capture from about 380 KB to about 100 KB.
