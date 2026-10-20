# TailwindCSS v4 Standards

## Key Changes from v3

- **CSS-first configuration**: Use `@theme` directive in CSS, not `tailwind.config.js`
- **Import syntax**: `@import "tailwindcss"` (not `@tailwind` directives)
- **CSS variables for tokens**: All design tokens as CSS vars (`--color-blue-500`, `--spacing-4`)
- **Dynamic spacing**: Every multiple of `--spacing: 0.25rem` works (e.g. `mt-21`)
- **No plugins needed**: Container queries built-in

```css
@import "tailwindcss";

@theme {
  --font-display: "Satoshi", "sans-serif";
  --color-brand-500: oklch(0.84 0.18 117.33);
}
```

## Renamed Utilities (v3 → v4)

| v3 | v4 |
|----|----|
| `shadow-sm` | `shadow-xs` |
| `shadow` | `shadow-sm` |
| `rounded-sm` | `rounded-xs` |
| `rounded` | `rounded-sm` |
| `blur-sm` | `blur-xs` |
| `blur` | `blur-sm` |
| `bg-opacity-50` | `bg-black/50` |
| `outline-none` | `outline-hidden` |
| `bg-[--brand]` | `bg-(--brand)` |

## UI Requirements

- Make all views responsive with breakpoints: `sm:`, `md:`, `lg:`, `xl:`, `2xl:`
- Colour with role utilities (`text-muted`, `bg-default`…), never palette steps or `dark:` for anything a role covers: [theming.md](theming.md)
- Shadows are elevation roles (`shadow-raised`, `shadow-overlay`…), never a raw step: [theming.md → Radius and shadow](theming.md#radius-and-shadow)
- Implement proper ARIA attributes for accessibility
- Use `dom_id` for HTML element IDs

## CSS Variables in Arbitrary Values

```html
<!-- v3 syntax (no longer works) -->
<div class="bg-[--brand-color]">

<!-- v4 syntax -->
<div class="bg-(--brand-color)">
```

## Component classes for repeated chrome (NON-NEGOTIABLE above ~100 elements)

Utilities are paid for **once per element**. That is the right trade almost
everywhere, and the wrong one where a string repeats across a grid: in the
framework explorer's edit matrix, twenty utility strings accounted for ~190 KB
of one response (`class` was 23% of the whole frame). Where a string repeats on
the order of hundreds of elements, define a plain CSS class in
`app/assets/tailwind/application.css` and use its name at the call site:

```css
/* app/assets/tailwind/application.css */
.mx-cell {
  padding: 0.625rem 0.75rem;
  vertical-align: top;
  border-bottom: 1px solid var(--gos-border-subtle);
  border-right: 1px solid var(--gos-border-subtle);
}
```

```ruby
td(id: cell_id, class: "mx-cell")   # was 74 characters of utilities, x282
```

Rules:

- **Colour with role variables** (`var(--gos-border-subtle)`, `var(--gos-content-muted)`),
  never hex or palette steps: a role already switches scheme and theme, so the
  rule needs no dark block ([theming.md](theming.md)).
- **Anything a role doesn't cover goes in `@variant dark` inside the rule**, never a
  `@media (prefers-color-scheme: dark)` block, which ignores `<html data-scheme>`.
  The class carries its own variants; the call site carries none.
- **These rules sit outside Tailwind's layers, so they BEAT a utility for the
  same property.** Never pair a component class with a utility that sets a
  property it declares. Put the variant in the class, or leave the whole thing
  a utility.
- **The class name is a literal at the call site**, so Hard-Won Lesson 12 (the
  JIT cannot see an interpolated class name) does not apply — there is nothing
  to interpolate.
- **Size child glyphs from the parent** (`.explorer-kebab > svg { width: 1rem }`)
  rather than putting `w-4 h-4` on every icon.
- **A one-off stays a utility.** This is for repetition, not for taste.

Existing examples: `.explorer-kebab` / `.explorer-cluster-btn` / `.explorer-add`
/ `.explorer-menu-item` (#380) and the `.mx-*` matrix family (#383) — see
[framework-explorer.md](framework-explorer.md) Hard-Won Lessons 29 and 33.

## Light and dark

The scheme rule, and what has to follow it, is in [theming.md → Light and dark](theming.md#light-and-dark).

## Container Queries (built-in, no plugin needed)

```html
<div class="@container">
  <div class="@md:flex-row flex-col flex">...</div>
</div>
```
