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
- Add dark mode support with `dark:` prefix
- Implement proper ARIA attributes for accessibility
- Use `dom_id` for HTML element IDs

## CSS Variables in Arbitrary Values

```html
<!-- v3 syntax (no longer works) -->
<div class="bg-[--brand-color]">

<!-- v4 syntax -->
<div class="bg-(--brand-color)">
```

## Container Queries (built-in, no plugin needed)

```html
<div class="@container">
  <div class="@md:flex-row flex-col flex">...</div>
</div>
```
