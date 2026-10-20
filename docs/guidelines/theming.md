# Theming and Lookbook

How colour, type and elevation reach the screen, and how to build, extend and check anything that uses them. The decision is [ADR-23](../architecture/adrs.md); the plan and its steps are [#539](https://github.com/mr-yum/growth-os/issues/539).

The short version: **colour with a role, never a palette step.** Write `text-muted`, not `text-gray-600 dark:text-gray-300`. A role carries both schemes and every theme, so it needs no `dark:` partner, and a theme can restyle it.

## The model

| Piece | What it is | Where it lives |
|---|---|---|
| **Role** | What a colour is for: `--gos-content-muted`, `--gos-surface-default`. One light and one dark value. | `app/assets/tailwind/theme/roles.css` |
| **Utility** | The Tailwind class for a role: `text-muted`, `bg-default`, `border-subtle`. | `@theme inline` at the foot of each theme file |
| **Theme** | A set of role values. | Default: `roles.css`. Bento: `theme/bento.css` on `html[data-theme="bento"]`. Custom: a tenant's values, injected by the layout. |
| **Tone** | A class (`tone-brand`, `tone-danger`…) that points the generic `--gos-tone-*` roles at one role set. | `@utility tone-*` in `roles.css` |
| **Domain palette** | Colours that carry assessment meaning: rating, score, activity. | `theme/domain.css` |
| **Categorical palette** | Eight hues for tags. | `theme/categorical.css` |
| **Contrast helper** | Black or white text for a fill a tenant picks. | the `@supports` blocks in `roles.css` |
| **Scheme rule** | When dark applies. | `@custom-variant dark` in `application.css` |

Role names follow Bento's vocabulary: content, surface, border, neutral, brand, accent, danger, success, warning, info, each with subtle, muted and strong steps and a `content-inverse` for text on the strong fill. GrowthOS adds a few roles Bento lacks: `surface-page`, `surface-overlay`, the two hover surfaces, `surface-field`, `scrim`, `content-link` and the nav pair.

Default's values point at the palette steps the app used before roles existed, so moving a class onto a role renders the same.

### Three themes

- **Default** looks the way GrowthOS always has.
- **Bento** sets every role, in both schemes, from the Bento design system, and its font, Plus Jakarta Sans.
- **Custom** starts from Default and takes a tenant's own values for the roles that have a `--tenant-*` hook (see [What Custom can set](#what-custom-can-set)).

A preset is a whole theme: under Default or Bento, a tenant's brand and font don't apply. Type is themed only by its family; sizes and weights are not.

### Light and dark

One rule, in `@custom-variant dark` (`app/assets/tailwind/application.css`): dark applies when the OS is dark, unless `<html data-scheme="light">`; `<html data-scheme="dark">` forces it. Role values, `dark:` utilities and `@variant dark` blocks all follow it. A person's choice (Auto, Light or Dark) is stored on `User#color_scheme` and reaches `<html data-scheme>` through `ColorSchemePreference`. The person picks it under Appearance in the user menu; the `color-scheme` controller sets `data-scheme` and the `theme-color` meta at once, then saves.

**Role values switch to dark only on `:root`.** An element with its own `data-scheme="dark"` (a dark panel on a light page) keeps the light `--gos-*` values, while any `dark:` utility inside it does switch, so the two disagree. Only the brand-derived roles re-derive inside `[data-theme-scope]`. Nothing needs a nested scheme today. One would need the dark role set repeated on the scoped element, as Bento does on its `.dark` class.

### The contrast helper

Text on a fill the tenant picks is computed, never chosen. `--gos-brand-content-inverse` and `--gos-nav-content` come from `contrast-color()`, with a relative-colour fallback that does the WCAG maths: black and white tie at relative luminance 0.17913, and the better of the two always reaches at least 4.58:1. It returns black or white only, one text colour per fill.

It runs only where a tenant picks the fill: brand, nav and Custom's surfaces. Presets set their designed text colours instead; Bento's lime carries near-black (`--gos-brand-content-inverse: #0a0d12` in `theme/bento.css`).

The helper can't see through a translucent fill, so fills under text are opaque mixes: `--gos-brand-subtle` is `color-mix(in oklab, var(--gos-brand) 10%, var(--gos-surface-default))`, never `bg-primary/10`.

## Which role to use

Most work needs only this table.

| Job | Utility |
|---|---|
| Body text, headings | `text-default` |
| Secondary text: help, metadata, captions | `text-muted` |
| Decorative glyphs only (an empty-cell `—`); fails AA as text | `text-subtle` |
| Disabled text | `text-disabled` |
| A link in running text | `text-link hover:text-link-hover` |
| The brand as text | `text-brand` |
| Status text | `text-danger`, `text-success`, `text-warning`, `text-info` |
| The page behind everything | `bg-page` |
| A card or panel | `bg-default` (or `Kit::Card`) |
| A popover, menu, tooltip or modal | `bg-overlay` |
| A quieter band inside a card, in steps | `bg-subtle`, `bg-muted`, `bg-emphasized` |
| Row hover on the page / on a card | `hover:bg-hover` / `hover:bg-default-hover` |
| A field's fill | `bg-field` (or `Kit::Field`) |
| The backdrop behind a modal | `bg-scrim` |
| An inverted block | `bg-inverse text-inverse` |
| A divider or card edge | `border-default`; fainter `border-subtle` |
| A stronger edge | `border-emphasized` |
| An input's edge | `border-field` (or `Kit::Field`) |
| A selected or editing edge | `border-strong` |
| A status edge | `border-danger`, `border-success`, `border-warning`, `border-info` |
| An invalid field | `Kit::Field::INVALID` (`border-danger-strong!`) |
| Keyboard focus | `outline-focus` or `ring-focus` |
| A neutral fill: chip, toggle, track | `bg-neutral-subtle`; selected `bg-neutral-muted` |
| A status message | `Kit::Alert` with `tone:` |
| A category | `Kit::Tag` with `category:` |
| A rating, score or activity type | the domain utilities: `bg-rating-some`, `text-rating-some-chip`, `text-score-below`, `bg-activity-self` |
| The navbar | `bg-nav text-nav` (Shell only) |

The Lookbook page **Design Tokens → Colour roles** lists every role with its utilities, its value under the current theme and scheme, and its measured contrast.

Strong fills (`bg-brand-strong`, `bg-danger-strong`, `bg-tone-strong`…) belong inside Kit components, which pair them with their text. A view that wants one wants a `Kit::Button` or a solid `Kit::Alert`.

## Fills and their content

Every fill has a content role that reads on it, and **the component picks the pair, not the call site.** A view never decides that white goes on brand.

Tones make that one line of classes. A `tone-*` class sets the generic tone roles:

```css
/* app/assets/tailwind/theme/roles.css */
@utility tone-danger {
  --gos-tone-strong: var(--gos-danger-strong);
  --gos-tone-subtle: var(--gos-danger-subtle);
  --gos-tone-content-strong: var(--gos-content-danger);
  --gos-tone-content-inverse: var(--gos-danger-content-inverse);
  --gos-tone-border: var(--gos-border-danger);
  /* … */
}
```

so a component styles itself once against the tone roles:

| Fill | Text on it |
|---|---|
| `bg-tone-strong` | `text-tone-content-inverse` |
| `bg-tone-subtle`, `bg-tone-muted` | `text-tone-content-strong` |
| `bg-default` with `border-tone` | `text-tone-content-strong` |

and the caller passes a meaning: `tone: :danger`. The tones are `neutral`, `brand`, `accent`, `danger`, `success`, `warning` and `info`.

### Which form and tone for which job

Variants are named for their **form** (`solid`, `subtle`, `outline`, `ghost`, `link`), never their job; meaning comes from `tone:`. There is no `primary` or `secondary` in the API. Pick by job:

| Job | `Kit::Button` |
|---|---|
| The main action on a view | `solid` · `brand` |
| An alternative beside it | `outline` · `neutral` |
| A quiet toolbar or row action | `ghost` · `neutral` |
| Confirm a destructive action | `solid` · `danger` |
| Start a destructive action | `ghost` or `outline` · `danger` |
| Navigation that reads as text | `link` · `brand` |

Labels follow the same rule:

- **`Kit::Alert` and `Kit::Toast`:** `tone:` for meaning, `emphasis: :subtle` (the default) or `:solid` for weight.
- **`Kit::Tag`:** a category hue from `category:`, hashed from a stable key so it keeps its hue on every screen; neutral without one.
- **`Kit::Chip`:** neutral always; selected is a neutral fill and a heavier weight, never brand.
- **`Kit::Badge`:** `tone:` for meaning, `variant: :subtle` (the default), `:solid` or `:outline` for weight, `size: :sm` or `:md`. Square, so it reads apart from a tag. The old job names (`variant: :primary`, `:success`…) still render as a subtle badge in the matching tone until each view moves.

## Building a themed component

`app/components/kit/button.rb` is the pattern. It keeps tone, form and size in separate constants and joins them:

```ruby
TONES = { neutral: "tone-neutral", brand: "tone-brand", danger: "tone-danger", … }.freeze

VARIANTS = {
  solid: "border-transparent bg-tone-strong text-tone-content-inverse hover:bg-tone-strong-hover …",
  outline: "bg-default border-tone text-tone-content-strong hover:bg-tone-subtle active:bg-tone-muted …",
  …
}.freeze

def self.classes(variant: :solid, tone: :neutral, size: :md, touch: false, icon: false)
```

What makes it themeable:

- **Only role and tone utilities.** No palette step, no `dark:`, no hex.
- **The fill and its text in the same string.** A call site can't put the wrong text on a fill.
- **Every state has a colour that clears AA**, disabled included. Where a pressed fill needs a step the roles lack, the component mixes it locally (`active:bg-[color-mix(in_oklab,…)]`) rather than adding a role.
- **A `.classes` class method** for call sites that can't render the component: `button_to`, `f.submit`, `link_to`. `Kit::Badge.classes` works the same way, and `Kit::Field` is constants only, because most fields come from form builders.
- **A strong fill resets the focus ring** to its own text colour, which already reads on it: `[--gos-focus-ring:var(--gos-tone-content-inverse)]` in `Kit::Alert`'s solid emphasis.
- **Icons use `currentColor`**, so they take the text role.

Then:

1. A preview in `test/components/previews/kit/<name>_preview.rb` (see [Lookbook](#lookbook)), checked under every theme and scheme.
2. A component test in `test/components/kit/<name>_test.rb`.
3. Its radius and shadow step in `test/lib/radius_shadow_steps_test.rb`.

### The guard tests

| Test | Fails when |
|---|---|
| `test/lib/kit_colour_roles_test.rb` | Kit, Shell, Shared, the controllers that write their classes, or a `.kit-*` / `.explorer-*` rule in `application.css` uses a palette colour |
| `test/lib/theme_roles_test.rb` | a role utility points at an undefined variable, or shares a name with a Tailwind colour or text size (`text-secondary`, `text-lg`) |
| `test/lib/domain_palette_tokens_test.rb` | a view colours a rating, score or activity with a palette step |
| `test/lib/brand_text_classes_test.rb` | `text-primary` or `text-secondary` is used as text |
| `test/lib/radius_shadow_steps_test.rb` | a Kit component leaves its radius or shadow step, or Shared or Shell adds a shadow |
| `test/lib/kit_previews_test.rb` | a Kit or Shared component has no preview |

Views join the palette guard as they migrate ([#544](https://github.com/mr-yum/growth-os/issues/544)–[#547](https://github.com/mr-yum/growth-os/issues/547)). Until then a view may still hold palette steps; new code in a view uses roles anyway.

## Reuse before you build

Check Kit and Lookbook before writing markup. If something close exists, extend it with a variant, tone, size or slot. A hand-rolled copy looks right on the day and drifts afterwards. The comment and evidence kebab menus hand-rolled `Kit::Dropdown`'s widget, so every fix, and the theming migration, had to land three times ([#555](https://github.com/mr-yum/growth-os/issues/555)).

The same goes for previews: render the real component, never a copy of its markup.

## Layers

| Layer | Holds | Example |
|---|---|---|
| `Components::Kit` | Generic primitives that know nothing about the product | Button, Field, Card, Alert, Tag, Chip, Modal, Dropdown |
| `Components::Shared` | Small compositions with one product job, built from Kit | ToConfirmChip, FrameLoadError |
| `Components::Shell` | Layout chrome around every page | Navbar, PageLayout, Sidebar, UserMenu |

Colour rules are the same in all three. Only Shell paints the nav roles, and only Kit paints strong fills.

## Radius and shadow

Tailwind's radius and shadow scales are the tokens, and they aren't themed. Each component owns one step, so elevation reads in order: cards below overlays below modals. Views never set radius or shadow on a Kit surface.

| Component | Radius | Shadow |
|---|---|---|
| `Kit::Card` | `rounded-2xl` | `shadow-xl` |
| `Kit::Card` `variant: :inset` | `rounded-md` | none |
| Overlays: `Kit::Dropdown`, `Kit::DefinitionTip`, `Kit::Toast` | `rounded-md` | `shadow-lg` |
| `Kit::Modal` | `rounded-lg` | `shadow-2xl` |
| `Kit::Button`, `Kit::Field`, `Kit::Alert` | `rounded-md` | none |
| `Kit::Badge` | `rounded-sm` | none |
| `Kit::Tag`, `Kit::Chip` | `rounded-full` | none |
| `Kit::EmptyState`, `Kit::DescriptionList` | `rounded-lg` | none |

## Focus and selection

- **Keyboard focus is neutral on every theme:** `--gos-focus-ring` is near-black in light and near-white in dark, never the brand. Use `focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus`, as `Kit::Button` does; the global `:focus-visible` rule in `application.css` covers bare elements.
- **On a coloured surface, reset the ring** to the surface's own text colour: the navbar sets `[--gos-focus-ring:var(--gos-nav-content)]`, a solid alert `var(--gos-tone-content-inverse)`.
- **A field shows focus by darkening its edge**, with no offset ring: `focus:border-strong focus:ring-1 focus:ring-inset focus:ring-focus` in `Kit::Field`.
- **Selected and highlighted items take a neutral fill**, never brand: `aria-pressed:bg-neutral-muted aria-pressed:font-semibold` in `Kit::Chip`. A Stimulus controller flips `aria-pressed` and lets the classes follow; it never writes colour classes.

## Extending the system

### Add a role

1. **Define it in `roles.css`** with Default's value in both schemes:

   ```css
   :root {
     --gos-surface-sunken: var(--color-gray-100);

     @variant dark {
       --gos-surface-sunken: var(--color-gray-900);
     }
   }
   ```

   A role computed from the brand goes in the `:root, [data-theme-scope]` block instead, so it re-derives inside a scope.
2. **Expose it** in `@theme inline`, under the property it's for. The namespaces are property-scoped, so this makes `bg-sunken` and nothing else:

   ```css
   --background-color-sunken: var(--gos-surface-sunken);
   ```

3. **Give every preset a value in both schemes**, in `theme/bento.css`. A preset that sets a role only in light keeps the light value in dark, because the preset's block outranks Default's dark values.
4. **Check the name**: `test/lib/theme_roles_test.rb` fails if it clashes with a Tailwind colour or text size.
5. **Look at it** on Lookbook's Colour roles page, which reads `roles.css` and shows the new role with its contrast, under each theme and scheme.

Reach for a new role only when no existing one does the job. Two near-identical roles become two spellings again.

### Add a preset

1. **A file** `app/assets/tailwind/theme/<name>.css` with one `html[data-theme="<name>"]` block that sets the font and every role, with an `@variant dark` block for the dark values. Copy `bento.css` for the shape. Import it in `application.css`.
2. **Set its text colours.** Presets set `--gos-*-content-inverse` to designed values; the contrast helper is only for fills a tenant picks.
3. **Register it:** `Themeable::THEMES` and `Themeable::PRESETS` (`app/models/concerns/themeable.rb`), its font in `PRESET_FONT_URLS`, its navbar in `NAV_SURFACES` for the browser chrome (the `--gos-nav-surface` values from its file, light and dark), and the `theme:` list in `config.lookbook.preview_display_options` (`config/environments/development.rb`). `?theme=<name>` (`DevThemeOverride`) reads `PRESETS`, so it needs nothing.

### Add a domain palette

Colours that carry meaning get a token each, whether or not a tenant can ever change them. Add the meanings to `theme/domain.css` (or `categorical.css` for hues with no meaning), with dark values and `@theme inline` utilities, and name them for the meaning: `--gos-score-below`, never `--gos-red-text`. `domain_palette_tokens_test.rb` then holds the views to them.

### What Custom can set

A Custom theme can set a role only if `roles.css` reads a tenant hook for it, with Default's value as the fallback:

```css
--gos-brand: var(--tenant-brand, #32c8c8);

@variant dark {
  --gos-brand: var(--tenant-brand-dark, #5ee0e0);
}
```

`Themeable::CUSTOM_ROLES` reads that list from `roles.css`, so adding a hook is all it takes to make a role settable. Today that is `brand` and `nav-surface`, plus the font family. A tenant's values are stored as `{ role => { "light" => hex, "dark" => hex } }` and injected on `:root` as `--tenant-<role>` and `--tenant-<role>-dark` by the layout's `#tenant-theme` block ([#550](https://github.com/mr-yum/growth-os/issues/550)). Text on those fills comes from the contrast helper, so a tenant never picks a text colour.

The Theme page that lets a tenant choose Default, Bento or Custom, and how Custom handles dark, is coming in [#551](https://github.com/mr-yum/growth-os/issues/551).

## Lookbook

Lookbook runs at `/lookbook` in development. Previews live in `test/components/previews/<layer>/<name>_preview.rb` and render in `app/views/layouts/component_preview.html.erb`, on the app's page surface with its stylesheets, import map and icon sprite.

- **A `playground` with `# @param` tags** for every argument, so anyone can try a combination. `Kit::ButtonPreview#playground` is the model.
- **Named groups for real states** (`# @!group Forms × tones` … `# @!endgroup`): every variant, tone and size, disabled, and the component in use (`dialog_footer`, `destructive_confirm`).
- **Render the real Kit component**, never a copy of its markup.
- **An ERB template only when a scenario needs markup the component doesn't render:** a Stimulus ancestor the component expects (an embedded `Kit::Modal` needs a `data-controller="modal"` host), a box around it (`kit/dropdown_preview/clipped.html.erb` clips the menu), or a script that sets its real state (`kit/modal_preview/open.html.erb` opens the dialog once its controller connects).
- **Realistic copy, with no class names in the prose.** Tailwind scans preview files, so a class name written in a sentence gets built into the CSS, and a class the component forgot to build will render in Lookbook and nowhere else.
- **Measure what you can.** `Kit::ButtonPreview#contrast` reads each state's fill and text from the component's own classes and measures them in the browser; the Colour roles page does the same for every role.
- **Check every preview under each theme and scheme** with the toolbar's gear icon (Theme: Default, Bento; Scheme: Auto, Light, Dark).
- **Every Kit and Shared component needs a preview;** `kit_previews_test.rb` fails without one. Shell previews are optional.

## Checking your work

1. **Lookbook**, every theme and scheme, for the component on its own.
2. **The app**, with the dev-only switch: `?theme=bento` and `?scheme=dark` (or `light`) on any URL. The choice sticks in a cookie until `?theme=default` or `?scheme=auto`.
3. **The stress tenant**, for long text, volume, every state and empty state, and hard brand colours (a yellow brand and a lime navbar). Seed it with `bin/rails dev:seed:stress`, then sign in as `admin@stress-test-co.example.com` / `password123`.
4. **Contrast:** text 4.5:1 and focus rings 3:1, on the surface the element actually sits on, in both schemes. The Lookbook pages above measure for you; for anything else, measure in the browser rather than trusting the value.
5. **The visual pass** in a real browser, which every front-end change needs ([chrome-mcp.md](chrome-mcp.md)).

## Don'ts

- **No palette steps for a UI role.** `text-gray-600`, `bg-white`, `border-gray-200`, `bg-primary` all have a role. Palette steps belong only inside token definitions.
- **No `dark:` for anything a role covers.** The role already switches.
- **No translucent fills under text** (`bg-primary/10`, `bg-red-900/30`). Use the subtle or muted role, which is an opaque mix.
- **No white text chosen by hand** on a fill that can change. Use the tone pair.
- **No brand for focus or selection.** Both are neutral.
- **No hand-rolled buttons, fields, alerts or menus.** Use `Kit::Button`, `Kit::Field`, `Kit::Alert`, `Kit::Dropdown`, or their `.classes`.
- **No hand-rolled copies of Kit components** in views or previews.
- **No radius or shadow on a Kit surface** from the call site.
- **No job names for variants** (`primary`, `secondary`, `cta`). Name the form; the tone carries the meaning.
