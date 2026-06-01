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

- Components: `Kit::ComponentName` → `app/components/kit/component_name.rb`
- Page views: `Views::Resource::ActionView` → `app/views/resource/action_view.rb`

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

## Slots Pattern

```ruby
Card(title: "User") do |card|
  card.body { render_user_info }
  card.actions { Button("Edit") }
end
```

## Controller Rendering

```ruby
class DashboardController < ApplicationController
  def show
    render Views::Dashboard::ShowView.new(user: current_user, stats: @stats)
  end
end
```

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

- **Muted/secondary text uses one AA-safe pairing: `text-gray-600 dark:text-gray-300`.** Do not reach for `text-gray-400`/`text-gray-500` for readable text — both fall below 4.5:1 on white/`gray-50` (and on `gray-800` cards in dark). The lighter greys are for genuinely incidental/decorative glyphs only (e.g. faint empty-cell `—` placeholders), never for content.
- **Coloured accent text on a light/neutral background needs `-700`, not `-600`** (`text-amber-700`, `text-green-700`, `text-red-700`). `blue-600` is the exception — it already clears AA. On the `-100` tinted fills used by `Kit::Badge`-style chips, go one darker again (`-800`).
- **Contrast depends on the background, so verify, don't eyeball.** A token that passes on white can fail on a `gray-50`/`gray-800` card. The same applies in reverse for dark mode — lighten the `dark:` variant, never just darken the light one.
- **An indicator that sits on a variably-coloured surface can't use a single text colour** — put it on a contrasting disc (e.g. the level-chip "rated" `✓` on `bg-white dark:bg-gray-900`) so it clears AA against any fill.

### Don't ship translucent text surfaces

A panel that holds readable content must be **opaque**. `dark:bg-gray-800/50` over the page or another component composites to a muddy, low-contrast surface (this bit the assessment activity sidebar). Reserve `/NN` alpha backgrounds for subtle highlights behind already-high-contrast text, not for content containers.

### Touch targets — 2.5.5 (≥44×44 CSS px)

Standalone interactive controls need a 44px hit area. Icon-only buttons use `h-11 w-11` with `inline-flex items-center justify-center`; standalone text links/rows use `min-h-11` (wrap a smaller visual in a 44px box rather than enlarging the visual — see `Kit::UserMenu`'s avatar). The inline-link exception only applies to links *within a sentence*.

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

`<html lang>`, the skip-to-content link, and the `main#main-content` landmark live in the layout / `Kit::PageLayout`. New top-level page views render inside that `<main>` — don't introduce a second `<main>` or bury page content outside it.

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
