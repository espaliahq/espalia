# Phlex Views and Kit Components

**Phlex is required for all new views and components. ERB is legacy only.**

## Rules

- All new page views MUST use Phlex (inherit from `Views::Base`)
- All new UI components inherit from `Components::Base` and live in a [layer](#component-layers)
- Do NOT create new ERB files — use ERB only for minor fixes to existing legacy views
- Use `view_template` method (not `template`)
- Render Kit components rather than hand-rolling their markup: `render Components::Kit::Card.new(title: "Theme")`
- Colour, radius, shadow and focus follow [theming.md](theming.md)
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

### Which Kit component

Look a job up here, then check its states in Lookbook (`/lookbook`) before writing markup.

| You need | Use |
|---|---|
| A button, or a link that looks like one | `Kit::Button.new(variant:, tone:, size:, href:)`: variants `:solid`, `:subtle`, `:outline`, `:ghost`, `:link` |
| An icon on its own | `Kit::Button.new(variant: :ghost, icon: true, aria_label:)` |
| A `button_to`, `f.submit` or `link_to` | `class: Kit::Button.classes(...)` |
| A toggle or filter, or a removable choice such as a person | `Kit::Chip.new(label, pressed:)`, `remove:` |
| One choice from a few, on a shared track | `Kit::SegmentedControl` |
| A menu, or one row in it | `Kit::Dropdown`; `Kit::Dropdown.item_classes(tone:, size:)` for a `button_to` row |
| A status or count (square) | `Kit::Badge.new(label, tone:)` |
| A level, role family or category (rounded) | `Kit::Tag.new(label, category:)` |
| A text field, select, textarea, checkbox or radio | `class: Kit::Field::INPUT`, `SELECT`, `TEXTAREA`, `CHECKBOX` or `RADIO`, with layout classes beside it |
| A panel, or a card that links | `Kit::Card` (`variant: :inset`, `href:`) |
| A message on the page, or one that comes and goes | `Kit::Alert`, `Kit::Toast` |
| Nothing to show yet | `Kit::EmptyState` |
| A dialog | `Kit::Modal` |

Examples of each are in [`app/components/README.md`](../../app/components/README.md). A button's variant is its form and its tone its meaning, so pick both by the job:

| Job | `Kit::Button` `variant:` · `tone:` |
|---|---|
| The main action on a view | `:solid` · `:brand` |
| An alternative beside it | `:outline` · `:neutral` |
| A quiet toolbar or row action | `:ghost` · `:neutral` |
| Confirm a destructive action | `:solid` · `:danger` |
| Start a destructive action | `:ghost` or `:outline` · `:danger` |
| Navigation that reads as text | `:link` · `:brand` |

**No option fits?** Add the option to the Kit component, with its preview, and use it. Copying the markup instead is how a fix ends up landing in five places.

### Options before copies

Each component owns its radius and shadow ([theming.md → Radius and shadow](theming.md#radius-and-shadow)), so views never set either on a Kit surface. Reach for an option before hand-rolling a near copy:

- **A grey panel inside a card:** `Kit::Card` `variant: :inset`. Add `density: :compact` for a list or grouped fields; compact also suits a small card of its own. `edge:` swaps its border for a state's, as the hero's verdict panel does.
- **A clickable card:** `Kit::Card` `href:` renders an `a` with one hover and focus treatment, so it can't hold other links. `interactive: true` gives a `div` the same look, and `data-focused="true"` holds it on.
- **A wide modal, or one whose body draws its own heading and ×:** `Kit::Modal` `size: :xl`, `:"2xl"` or `:"3xl"` (the evidence modals, 768px), and `header: false`. The title still names the dialog.
- **A controller that must wrap the whole modal body** (a lazy frame's `frame-error`, `submit-fallback`): pass it as `Kit::Modal` `panel_data:`. The evidence shells do.

## Page View Pattern

```ruby
# app/views/dashboard/show_view.rb
class Views::Dashboard::ShowView < Views::Base
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

      render Components::Kit::Card.new(title: "Recent Activity") do |card|
        card.body { render_activity }
        card.actions do
          render Components::Kit::Button.new(variant: :link, tone: :brand, href: activities_path) { "View all" }
        end
      end
    end
  end

  private

  def stat_card(label, value)
    render Components::Kit::Card.new do |card|
      card.body do
        p(class: "text-sm text-muted") { label }
        p(class: "text-3xl font-bold") { value }
      end
    end
  end
end
```

## Kit Component Pattern

`app/components/kit/button.rb` is the model: a constant per axis (tone, form, size), a `.classes` class method for call sites that can't render the component, and `view_template` joining them. How it stays themeable is in [theming.md → Building a themed component](theming.md#building-a-themed-component).

```ruby
# app/components/kit/button.rb (abridged)
class Components::Kit::Button < Components::Base
  TONES = { neutral: "tone-neutral", brand: "tone-brand", danger: "tone-danger", … }.freeze
  VARIANTS = { solid: "border-transparent bg-tone-strong text-tone-content-inverse …", … }.freeze

  def self.classes(variant: :solid, tone: :neutral, size: :md, touch: false, icon: false) = …

  def initialize(variant: :solid, tone: :neutral, size: :md, href: nil, type: :button, **attrs)
    @classes = self.class.classes(variant:, tone:, size:)
    …
  end

  def view_template(&)
    @href ? a(**element_attrs, href: @href, &) : button(**element_attrs, type: @type, &)
  end
end
```

## Previewing components (Lookbook)

[Lookbook](https://lookbook.build) shows Kit components on their own at **`/lookbook`** in development. Build or restyle a component there, state by state, before wiring it into a view. How to write a preview, and what the completeness test demands, is in [theming.md → Lookbook](theming.md#lookbook).

## Slots Pattern

```ruby
render Components::Kit::Card.new(title: "User") do |card|
  card.body { render_user_info }
  card.actions { render Components::Kit::Button.new(variant: :outline) { "Edit" } }
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
does not scale to a grid). The explorer's role tree uses `Kit::Dropdown` with
`Concerns::KebabChrome#kebab_trigger`. Everywhere else, `Kit::Dropdown#trigger(label:,
button: { variant: :ghost, size: :xs, icon: true })` draws the ⋮ and its ARIA, and
`#item` (or `.item_classes` on a `button_to`) draws each entry, as the comment and
evidence cards do.

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
class Views::Frameworks::ShowView < Views::Base
  def initialize(framework:, is_admin:)
    @framework = framework
    @is_admin = is_admin
  end

  def view_template
    # Admin-only UI gated by the flag
    if @is_admin
      render Components::Kit::Button.new(variant: :outline, href: framework_settings_path(@framework)) { "Settings" }
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

Colour with role utilities, and check contrast on the surface an element actually sits on, in both schemes. Which role to use, opaque fills under text, and how to measure are in [theming.md](theming.md). A view still on palette steps keeps its AA pairings (`text-gray-600 dark:text-gray-300` for muted text, `-700` for coloured text) until it moves; don't tune them, move what you touch onto roles.

### Touch targets

- **Every target is at least 24×24**, or has 24px of clear space around it (WCAG 2.5.8, AA). A link inside a sentence is exempt. This floor can't be traded away.
- **`Kit::Button` takes a tap across 44px by default, at the size it looks:** an invisible `::after`, centred on the button and at least 44px square. The box is positioned, so it paints, and takes the tap, over any neighbour that isn't positioned itself, whatever the DOM order; between two buttons the later one wins.
- **Pass `compact: true` where that box would cover a neighbour's face, or where the design wants the tight version:** a tight icon row, a toolbar that wraps, a Save or Post under its textarea, a row of actions above another control, a `variant: :link` button inside a sentence, a button in a sticky header (its box would spill over the content scrolling under it), and a small button in the last row of an `overflow-x-auto` table (2px of hit area below it adds a scrollbar). `Kit::Modal` pads its scroll box, so a footer button needs nothing. A larger target already around the button also makes the box redundant.
- **Find stolen taps** by probing each control's edges with `document.elementFromPoint`: a point that lands on another button, outside that button's own box, and would reach the control with the box switched off is one. `assert_no_stolen_taps` does this in system tests.
- **`touch: true` makes the visual itself 44px**, for a key action on a touch screen that should look the size it taps. An `<input type="submit">` can't carry a pseudo-element, so build an `f.submit`'s class with `Components::Kit::Button.classes(…, touch: true)`; `touch: true` passed to the form builder only becomes an HTML attribute.
- **A control that isn't a `Kit::Button`** aims for 44px when it's a key action on a touch screen: the main action on a view, a control people tap often, an icon that is the only way to do something. Size it with `pointer-coarse:` (`pointer-coarse:min-h-11`, as `Kit::SegmentedControl` does) so it stays compact under a mouse, or wrap a smaller visual in a 44px box, as `Shell::UserMenu`'s avatar does. Design direction can override the 44px aim; never the 24px floor.

### Accessible names

- **Every form field needs a programmatic name** — a `<label for>`, `aria-labelledby`, or `aria-label`. A `placeholder` is **not** a name (it disappears and isn't reliably announced). Comment/inline composers must carry `aria: { label: "…" }`.
- **Icon-only controls** carry `aria: { label: "…" }`; the icon itself is `aria: { hidden: "true" }`.
- **Decorative glyphs** (separators, faint placeholders) get `aria: { hidden: "true" }` so they aren't announced.

### Graphical widgets need ARIA semantics — 4.1.2

A bar/meter built from `<div>`s conveys nothing to AT and must not rely on colour/width alone (1.4.1). Add `role: "progressbar"` with `aria: { valuenow:, valuemin: 0, valuemax: 100, label: "…" }` (see the cohort funnel bars). Prefer a text equivalent where one already exists (e.g. the Home funnel renders `Self 0%` as text — no widget needed).

### Heading order — 1.3.1 / 2.4.10

Headings descend sequentially; never skip a level for styling. `Kit::Card` takes `heading_level:` (default `:h3`) — pass `:h2` when a card title is the next level under the page `h1` so the outline stays sequential (the Home dashboard cards do this).

### Keyboard focus — 2.4.7

A global `:focus-visible` ring in `app/assets/tailwind/application.css` covers bare elements. Never remove an outline without a visible focus state in its place; the colours and patterns are in [theming.md → Focus and selection](theming.md#focus-and-selection).

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

## Kit in a legacy ERB view

A minor fix to an ERB view renders the Phlex component, or uses its `.classes` on a Rails helper:

```erb
<%= render Components::Kit::Alert.new(tone: :success) { "Saved" } %>
<%= f.submit "Save", class: Components::Kit::Button.classes(tone: :brand) %>
```

Variants are named for their form and take a `tone:`; which pair suits which job is in [Which Kit component](#which-kit-component).
