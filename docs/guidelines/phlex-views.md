# Phlex Views and Kit Components

**Phlex is required for all new views and components. ERB is legacy only.**

## Rules

- All new page views MUST use Phlex (inherit from `ApplicationView`)
- All new UI components MUST use Kit pattern (inherit from `ApplicationComponent`)
- Do NOT create new ERB files — use ERB only for minor fixes to existing legacy views
- Use `view_template` method (not `template`)
- Use semantic Kit helpers: `Button()`, `Card()`, `Alert()`, `Badge()`, `Avatar()`
- Give interactive/form elements accessible names — prefer a native `<label>` or `aria-labelledby`, and reserve `aria-label` for controls with no visible label (see [Accessibility](#accessibility-non-negotiable))

## Naming Conventions

- Components: `Components::<Layer>::ComponentName` → `app/components/<layer>/component_name.rb`
- Page views: `Views::Resource::ActionView` → `app/views/resource/action_view.rb`

## Component layers

`app/components/` holds three layers, each a namespace and a Lookbook group:

| Layer | Holds | Put a new component here when |
|---|---|---|
| `Components::Kit` | Generic primitives: Badge, Card, Modal, Dropdown, DefinitionTip, DescriptionList, Prose, SectionHeading, IconSprite | it's named for what it is and knows nothing about the product |
| `Components::Shared` | Small compositions with one job, built only from Kit: ToConfirmChip, FrameLoadError, SubmitFallbackMessage | it does one product job and several views need it |
| `Components::Shell` | The app's layout chrome: Navbar, PageLayout, Sidebar, UserMenu, TenantAdminLayout, ImpersonationBanner | it frames every page |

Anything used by one screen stays with that screen's views, not here.

## Page View Pattern

```ruby
# app/views/dashboard/show_view.rb
class Views::Dashboard::ShowView < ApplicationView
  def initialize(user:, stats:)
    @user = user
    @stats = stats
  end

  def view_template
    div(class: "container px-4 mx-auto my-8") do
      h1(class: "h2 mb-6") { "Welcome, #{@user.first_name}!" }

      div(class: "grid grid-cols-1 md:grid-cols-3 gap-6") do
        stat_card("Streak", "#{@stats[:streak]} days")
        stat_card("Points", @stats[:points].to_s)
      end

      Card(title: "Recent Activity") do |card|
        card.body { render_activity }
        card.actions { Button("View All", variant: :link, href: activities_path) }
      end
    end
  end

  private

  def stat_card(label, value)
    Card do |card|
      card.body do
        p(class: "text-sm text-muted") { label }
        p(class: "text-3xl font-bold") { value }
      end
    end
  end
end
```

## Kit Component Pattern

```ruby
# app/components/kit/button.rb
module Kit
  class Button < ApplicationComponent
    VARIANTS = {
      primary: "btn btn-primary",
      secondary: "btn btn-secondary",
      danger: "btn btn-danger"
    }.freeze

    def initialize(label = nil, variant: :primary, size: :md, **attributes)
      @label = label
      @variant = variant
      @size = size
      @attributes = attributes
    end

    def view_template(&block)
      button(**button_attributes) do
        block ? yield : @label
      end
    end

    private

    def button_attributes
      merge_attributes({ type: "button", class: VARIANTS[@variant] }, @attributes)
    end
  end
end
```

## Previewing components (Lookbook)

[Lookbook](https://lookbook.build) shows Kit components on their own, outside any page, at **`/lookbook`** in development. Use it to build or restyle a component, state by state, before wiring it into a view.

- **One preview class per component**, in `test/components/previews/<layer>/<name>_preview.rb`, subclassing `Lookbook::Preview`. Each public method is one scenario; wrap related scenarios in `# @!group` / `# @!endgroup` to show them side by side.
- **A `playground` scenario with `# @param` tags** gives live controls (text fields, selects) in the Lookbook UI.
- **Previews render in `layouts/component_preview.html.erb`**: the app's stylesheets, import map and icon sprite on the page surface, so Tailwind, the colour roles and Stimulus behave as they do in the app. There's no tenant, so no tenant theme and no `PageLayout`. The toolbar's gear icon switches **Theme** and **Scheme** for every preview.
- **Development only.** The gem is in the `:development` group and the engine mounts only there, so nothing here reaches production. Lookbook pulls in the `view_component` gem as a dependency; don't write ViewComponents.

- **What's there:** **Design Tokens** (the colour roles, read from `theme/roles.css`, and the brand tokens, read from `application.css`, so a new one appears on its own, each with its measured contrast; a proof of the contrast helper; the Tailwind palette and the type scale), then **Kit** (with an **Icons** gallery), **Shared** and **Shell**. Only the Sidebar is previewed from the Shell so far.
- **Every Kit and Shared component needs a preview.** `test/lib/kit_previews_test.rb` fails when one is missing. Previewing the Shell is optional.
- **The sidebar sorts folders alphabetically** and its path is the URL, so moving a preview changes its link. `# @label`, `# @logical_path` and `# @priority` rename, move and order a preview without moving the file.
- **A class that appears only in a preview is still built into the CSS.** Pass a component its real arguments; don't write its class names into the preview, or a class the component builds by interpolation will render in Lookbook and nowhere else.

## Slots Pattern

```ruby
Card(title: "User") do |card|
  card.body { render_user_info }
  card.actions { Button("Edit") }
end
```

**Deferred slot blocks run in the CALLER's context, not the component's.** When a
component stores a slot block to render later (e.g. `Kit::Modal` captures
`body`/`trigger` and emits them inside its overlay markup), invoke it with
`@block.call`, **never** `instance_exec(&@block)`. The block almost always calls
methods/ivars on the view that rendered the component (`form_body`, `@assignment`,
`render SomeView.new`); `instance_exec` rebinds `self` to the component and those
break. Phlex shares the output buffer across the nested render, so `@block.call`
still emits in the right position. A bare string returned from such a block is
NOT auto-rendered (unlike a block passed directly to an element) — real slot
bodies emit (call `render`/`p`/`form`), which is why this works in practice.
`Kit::Modal` is the reference: standalone (own `modal` controller + a `trigger`
slot) or embedded (`standalone: false` — overlay only, an ancestor provides the
controller, for many remote triggers sharing one modal).

## Inline-edit affordances (pencil placement)

An inline-edit pencil (or equivalent hover-revealed edit control) sits
**immediately to the right of the text it edits**, never pushed to the far edge
of its container. The text takes only its content width and the pencil follows
it directly:

```ruby
# Good — pencil hugs the text
div(class: "flex items-start gap-1", data: { inline_editor_target: "display" }) do
  span(class: "...") { @text }          # no flex-1 / flex-grow on the text
  render_inline_editor_pencil(aria_label: "Edit …")  # shrink-0
end

# Bad — flex-1 on the text shoves the pencil to the far side of the cell
span(class: "flex-1 ...") { @text }
render_inline_editor_pencil(aria_label: "Edit …")
```

Rules:
- The display wrapper is `flex items-start gap-1`; the text element carries **no
  `flex-1`/`flex-grow`** and the pencil is `shrink-0`.
- Reuse `Views::Frameworks::Explorer::Concerns::InlineEditable#render_inline_editor_pencil`
  (hover/focus reveal via the `group/ine` token) rather than re-rolling the
  control, so behaviour and styling stay uniform.
- The pencil belongs in the same visual line as the value, so the edit target is
  unambiguous — a control floated to the opposite edge reads as unrelated.

## Kebab (⋮) menus — always the right-most control

A kebab reads as "…more" — the overflow home for a row's secondary actions. Two
rules, both non-negotiable:

- **The kebab is always the right-most control in its cluster.** Primary
  single-purpose affordances (the inline-edit pencil, a Discuss bubble) come
  before it; nothing renders after it. A kebab followed by more buttons
  contradicts its own "more" semantics.
- **Secondary and destructive actions live inside the kebab, not beside it.**
  Archive/delete, dialogs, and approve/reject controls are menu items; only the
  highest-frequency direct affordance (typically the pencil) earns a standalone
  spot. A hover cluster that accumulates one standalone button per action also
  permanently reserves row width (`opacity-0` still occupies layout) and
  crushes the text it decorates — the role tree learned this the hard way, and
  then learned the second half: **where the text is tight, take the cluster out
  of the flow entirely** and float it over the row's right edge, masked only
  while it is revealed (framework-explorer.md §11a).

Use a shared trigger rather than hand-rolling the ⋮ glyph, and make sure the
trigger stays visible on `pointer-coarse` so touch devices aren't left with an
invisible control. In the framework explorer's grid that is
`Views::Frameworks::Explorer::Concerns::MenuItems#render_menu_trigger` — a bare
trigger whose menu one root-mounted controller builds on open (see
[framework-explorer.md](framework-explorer.md) §11a; a per-kebab `Kit::Dropdown`
does not scale to a grid). Elsewhere — and in the explorer's role tree — use
`Kit::Dropdown` with `Concerns::KebabChrome#kebab_trigger`.

## Controller Rendering

```ruby
class DashboardController < ApplicationController
  def show
    render Views::Dashboard::ShowView.new(user: current_user, stats: @stats)
  end
end
```

## Text people write: render it through `Kit::Prose`

Feedback, comments, notes and rationale are stored exactly as typed and may
contain Markdown. Show them with `render Components::Kit::Prose.new(text,
class: …)` — never as a bare string in a `whitespace-pre-wrap` element, and
never with your own `raw`. `Kit::Prose` is the only component that emits
`::Prose` HTML, so the sanitizer's allowlist is the whole security story
([#482](https://github.com/mr-yum/growth-os/issues/482)).

- **Excerpts use `Prose.to_plain(text)`** — feed lines, notification bodies,
  previews, anything truncated or `line-clamp`ed. It reads as the text a
  person sees, so `**` and `[…](…)` never show as punctuation, while a link
  keeps its URL in brackets so a Slack excerpt can still be followed.
- **Framework content stays plain.** Expectation text, illustrations and
  suggested values are rendered the same way everywhere the matrix shows them;
  Markdown there would make a cell read differently in two places.
- **The field's main composer says so.** Put `Prose::COMPOSER_HINT` beside
  it and point the textarea's `aria-describedby` at the hint. A thread's
  inline edit and reply forms write the same field, so they don't repeat it.
  An MCP tool that writes such a field declares `prose_fields :name`
  ([mcp-server.md](mcp-server.md)).
- **The wrapper is a `div`.** Rendered Markdown contains block elements, so a
  `<p>` parent produces invalid nesting.

## Attribute values: pass strings, not symbols

Phlex dasherizes a **Symbol attribute value** the way it dasherizes keys, so
`input(type: "hidden", name: :as_role)` renders `name="as-role"` — and the
controller silently receives no `as_role` param. Anything that becomes a param
name or an id must be a String (`name: key.to_s`), which matters most when the
names come from a hash of symbols (e.g. `Assessments::Lens#to_params`).

## `format` is not `Kernel#format` inside a view

A Phlex view inherits a `format` method of its own, so
`format("%.1f", mean)` in a component raises `ArgumentError: wrong number of
arguments (given 2, expected 0)` at render. Use `sprintf` (or
`Kernel.format`), as the calibration views do.

## Conditional Rendering by Permission (NON-NEGOTIABLE)

**Never query policies or check roles directly in views.** Controllers resolve permissions and pass boolean flags.

```ruby
# Controller — resolves permission, passes flag
def show
  authorize @framework
  render Views::Frameworks::ShowView.new(
    framework: @framework,
    is_admin: policy(@framework).admin?
  )
end

# View — receives flag, renders conditionally
class Views::Frameworks::ShowView < ApplicationView
  def initialize(framework:, is_admin:)
    @framework = framework
    @is_admin = is_admin
  end

  def view_template
    # Admin-only UI gated by the flag
    if @is_admin
      Button("Settings", href: framework_settings_path(@framework))
    end
  end
end
```

**Anti-pattern:**

```ruby
# Bad — querying policy in view
def view_template
  if FrameworkPolicy.new(auth_context, @framework).admin?
    render_admin_ui
  end
end

# Bad — checking role directly
def view_template
  if @current_user.global_admin?
    render_admin_ui
  end
end
```

## Accessibility (NON-NEGOTIABLE)

Target **WCAG 2.1 AA**. Every view and Kit component must hold the line on the
rules below — they were paid for once and regress silently. Validate UI changes
with the chrome-devtools MCP (see [chrome-mcp.md](chrome-mcp.md)) in **both light
and dark** and at a **mobile viewport**, then pin regressions with a test.

### Colour contrast — 1.4.3 (4.5:1 normal text, 3:1 large/≥18.66px-bold)

- **New code colours itself with role utilities** (`text-muted`, `bg-default`, `border-subtle`, `text-danger`, `bg-tone-strong`…), defined in `app/assets/tailwind/theme/roles.css` ([ADR-23](../architecture/adrs.md)). A role carries both schemes, so it needs no `dark:` partner. The palette rules below still hold for code not yet moved onto roles (#539).
- **Muted/secondary text uses one AA-safe pairing: `text-gray-600 dark:text-gray-300`.** Do not reach for `text-gray-400`/`text-gray-500` for readable text — both fall below 4.5:1 on white/`gray-50` (and on `gray-800` cards in dark). The lighter greys are for genuinely incidental/decorative glyphs only (e.g. faint empty-cell `—` placeholders), never for content.
- **Coloured accent text on a light/neutral background needs `-700`, not `-600`** (`text-amber-700`, `text-green-700`, `text-red-700`). `blue-600` is the exception — it already clears AA. On the `-100` tinted fills used by `Kit::Badge`-style chips, go one darker again (`-800`).
- **Brand-coloured text uses `text-primary-ink`, never `text-primary`.** The brand teal is 2:1 on white, and a tenant can set any primary, so `--color-primary-ink` clamps the active primary's OKLCH lightness (≤0.5 light, ≥0.75 dark) to clear 4.5:1 whatever the tenant chose. `text-primary` survives only where it paints a checkbox or radio mark; fills (`bg-primary/10`), borders and focus rings keep the brand colour. A faded hover (`hover:text-primary-ink/80`) drops below AA — hover with `hover:underline` instead.
- **Don't add new white text on `bg-primary`, or new `ring-primary` focus rings.** The default teal carries neither: white on it is 2.0:1 (1.5:1 in dark mode), and a teal ring on white is 2.0:1 against the 3:1 a focus indicator needs. The existing sites are tracked in [#447](https://github.com/mr-yum/growth-os/issues/447), which adds a darker `--color-primary-strong` fill. Until then, a pressed chip uses the neutral pairing (`bg-gray-900 text-white dark:bg-white dark:text-gray-900`).
- **Contrast depends on the background, so verify, don't eyeball.** A token that passes on white can fail on a `gray-50`/`gray-800` card. The same applies in reverse for dark mode — lighten the `dark:` variant, never just darken the light one.
- **An indicator that sits on a variably-coloured surface can't use a single text colour** — put it on a contrasting disc (e.g. the level-chip "rated" `✓` on `bg-white dark:bg-gray-900`) so it clears AA against any fill.

### Don't ship translucent text surfaces

A panel that holds readable content must be **opaque**. `dark:bg-gray-800/50` over the page or another component composites to a muddy, low-contrast surface (this bit the assessment activity sidebar). Reserve `/NN` alpha backgrounds for subtle highlights behind already-high-contrast text, not for content containers.

### Touch targets — 2.5.5 (≥44×44 CSS px)

Standalone interactive controls need a 44px hit area. Icon-only buttons use `h-11 w-11` with `inline-flex items-center justify-center`; standalone text links/rows use `min-h-11` (wrap a smaller visual in a 44px box rather than enlarging the visual — see `Shell::UserMenu`'s avatar). The inline-link exception only applies to links *within a sentence*.

### Accessible names

- **Every form field needs a programmatic name** — a `<label for>`, `aria-labelledby`, or `aria-label`. A `placeholder` is **not** a name (it disappears and isn't reliably announced). Comment/inline composers must carry `aria: { label: "…" }`.
- **Icon-only controls** carry `aria: { label: "…" }`; the icon itself is `aria: { hidden: "true" }`.
- **Decorative glyphs** (separators, faint placeholders) get `aria: { hidden: "true" }` so they aren't announced.

### Graphical widgets need ARIA semantics — 4.1.2

A bar/meter built from `<div>`s conveys nothing to AT and must not rely on colour/width alone (1.4.1). Add `role: "progressbar"` with `aria: { valuenow:, valuemin: 0, valuemax: 100, label: "…" }` (see the cohort funnel bars). Prefer a text equivalent where one already exists (e.g. the Home funnel renders `Self 0%` as text — no widget needed).

### Heading order — 1.3.1 / 2.4.10

Headings descend sequentially; never skip a level for styling. `Kit::Card` takes `heading_level:` (default `:h3`) — pass `:h2` when a card title is the next level under the page `h1` so the outline stays sequential (the Home dashboard cards do this).

### Keyboard focus — 2.4.7

A global `:focus-visible` ring lives in `app/assets/tailwind/application.css` (2px, offset, blue-700/blue-300). **Never reset an outline (`outline-hidden`/`focus:outline-none`) without providing an equivalent visible focus state** — a per-component `focus:ring-2` is fine, a bare reset is not.

### Document structure (layout-level, but views rely on it)

`<html lang>`, the skip-to-content link, and the `main#main-content` landmark live in the layout / `Shell::PageLayout`. New top-level page views render inside that `<main>` — don't introduce a second `<main>` or bury page content outside it.

## Turbo Frames

Page regions can lazy-load via `turbo_frame_tag(name, src:, loading: "lazy")`:
the frame renders a placeholder, then fetches its real content from a controller
action that re-renders a frame with the **same id**. The Home dashboard cards,
the framework-explorer suggestion panel, and the assessment matrix all use this.

**Navigation links and forms inside a frame must target `_top` (or another
frame) explicitly (NON-NEGOTIABLE).** A bare `<a>`/`<form>` inside a
`turbo_frame_tag` navigates *within that frame*; if the response is a full page
with no matching `<turbo-frame id=name>`, Turbo renders **"Content missing"**
instead of navigating. Add `data: { turbo_frame: "_top" }` to any in-frame
control that should drive a full-page navigation:

```ruby
turbo_frame_tag("home-card-cycle_progress-#{cycle.cycle_id}") do
  Card(...) do |card|
    card.actions do
      # Full-page nav — must break out of the lazy card frame
      a(href: cohort_assessment_cycle_path(cycle),
        data: { turbo_frame: "_top" }) { "View progress →" }
    end
  end
end
```

This bug is invisible to a system test that `visit`s the destination path
directly — only clicking the in-frame link reproduces it, so exercise the real
click path (see [testing.md](testing.md) and [chrome-mcp.md](chrome-mcp.md)).

**Table rows are the one place a lazy frame can't go.** The HTML parser
foster-parents a `<turbo-frame>` out of a `<tbody>`, and a frame inside a
single spanning `<td>` can't produce per-column cells, so the explorer's
on-demand expanded row is fetched by its Stimulus controller and swapped in
as a `<tr>` parsed through a `<template>` — reusing `Shared::FrameLoadError`
(with `retry_action:`) for the failure state so the vocabulary stays one
(see [framework-explorer.md](framework-explorer.md), Hard-Won Lesson 25).
For the related rule that a frame's re-render response must carry the same
`mode:` / permission flags / counts as the initial render, see
[framework-explorer.md](framework-explorer.md) Hard-Won Lessons 13 & 16.

## ERB Bridge (Legacy Views Only)

When making minor updates to existing ERB views, use Kit helpers:

```erb
<%= kit_button "Save", variant: :primary %>
<%= kit_card(title: "Settings") { render "form" } %>
<%= kit_alert "Success!", variant: :success %>
<%= kit_badge "New", variant: :primary %>
<%= kit_avatar src: url, name: name %>
```

**Kit variants:**
- Buttons: `:primary`, `:secondary`, `:tertiary`, `:danger`, `:success`, `:link`
- Alerts: `:info`, `:success`, `:warning`, `:danger`
- Badges: `:primary`, `:secondary`, `:success`, `:warning`, `:danger`, `:info`
