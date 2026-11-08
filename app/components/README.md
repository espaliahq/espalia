# Components

Build screens from these before writing markup of your own. To find the one for a job, start at [phlex-views.md → Which Kit component](../../docs/guidelines/phlex-views.md#which-kit-component). If something close exists, add a variant, tone or slot to it rather than copying it.

| Layer | Holds | Examples |
|---|---|---|
| `Components::Kit` | Generic primitives that know nothing about the product | Button, Card, Alert, Field, Modal |
| `Components::Shared` | Small pieces with one product job, built only from Kit | ToConfirmChip, FrameLoadError, SubmitFallbackMessage |
| `Components::Shell` | The chrome around every page | PageLayout, Navbar, Sidebar, UserMenu, TenantAdminLayout |

Anything only one screen uses stays with that screen's views.

## See them in Lookbook

Run the app and open `/lookbook` (development only). Every Kit component has a playground with live options, plus a page for each of its real states, in any scheme. **Design Tokens → Colour roles** lists every colour role with its measured contrast. Previews live in `test/components/previews/`, and `test/lib/kit_previews_test.rb` fails when a Kit component has none.

## Form and tone

A Kit component never takes a colour. It takes a **form** (`variant:` or `emphasis:`), which sets its weight, and a **tone** (`tone:`), which carries its meaning. The component pairs each fill with text that reads on it.

Tones: `:neutral`, `:brand`, `:info`, `:success`, `:warning`, `:danger`. There is no `primary` or `secondary`.

## Kit

### Actions

**`Kit::Button`**: a button, or a link that looks like one (`href:`). Which variant and tone for which job: [phlex-views.md → Which Kit component](../../docs/guidelines/phlex-views.md#which-kit-component).

```ruby
render Components::Kit::Button.new(tone: :brand, type: :submit) { "Save ratings" }
render Components::Kit::Button.new(variant: :outline, href: assessment_path(assessment)) { "Open" }
render Components::Kit::Button.new(variant: :ghost, icon: true, aria_label: "Edit") { icon(:pencil, class: "size-4") }

# Where the component can't render: button_to, f.submit, link_to
button_to "Delete", path, method: :delete, class: Components::Kit::Button.classes(tone: :danger)
```

Sizes `:xs`, `:sm`, `:md`; `touch: true` makes it at least 44px square.

**`Kit::Dropdown`**: a menu behind a trigger.

```ruby
render Components::Kit::Dropdown.new do |dropdown|
  dropdown.trigger(label: "Comment actions", button: { variant: :ghost, size: :xs, icon: true }) { icon("kebab", class: "size-4") }
  dropdown.menu do
    dropdown.item(href: edit_path) { "Edit" }
    dropdown.item(tone: :danger, data: { action: "comment#delete" }) { "Delete" }
  end
end
```

Use `strategy: :fixed` inside a scrolling container, so the menu isn't clipped.

**`Kit::SegmentedControl`**: one choice from a few, on a shared track.

```ruby
render Components::Kit::SegmentedControl.new(label: "Activity feed focus mode", size: :sm) do |control|
  control.segment("Highlight", data: { action: "activity-feed#setMode" })
  control.segment("Filter", selected: true, data: { action: "activity-feed#setMode" })
end
```

A segment given `href:` is a link to that view of the page. Inside a menu, pass `item_role: :menuitemradio`. `marked: "needs your attention"` puts a dot after a segment's label for a view that holds something to look at; the string is read to a screen reader. `short: "Team"` swaps in a shorter label below the `sm` breakpoint, for a track too wide for a phone.

**`Kit::AttentionDot`**: a brand dot saying something needs the viewer, as on a conversation row. The label is read to a screen reader.

```ruby
render Components::Kit::AttentionDot.new("needs your attention", class: "ml-1.5")
```

**`Kit::Modal`**: a dialog that closes on Esc and locks the page's scroll.

```ruby
render Components::Kit::Modal.new(id: "delegate-modal", title: "Delegates") do |modal|
  modal.trigger { "Delegates" }
  modal.body { … }
end
```

`standalone: false` renders only the dialog, for one modal opened from many places on the page. A background click closes it only with `dismiss_on_outside_click: true`; leave that off for a modal that holds input.

### Labels

| Component | For | Example |
|---|---|---|
| `Kit::Badge` | A status or count. Square. | `Badge.new("Aligned", tone: :success)` |
| `Kit::Tag` | A classification: level, role family, category. Fully rounded. | `Tag.new("Delivery", category: capability.stable_id)` |
| `Kit::Chip` | A toggle that filters or picks, or a removable pick | `Chip.new("This cycle", pressed: true)` |
| `Kit::DefinitionTip` | A term whose definition shows on hover and keyboard focus | `DefinitionTip.new("Self-gap", definition: "…", id: "deftip-self-gap")` |

A tag's `category:` hashes a stable key to one of eight hues, so the same category keeps its colour on every screen. Chips stay neutral; selected is a heavier neutral fill, never brand.

### Messages

```ruby
render Components::Kit::Alert.new(tone: :danger, title: "The last publish failed") do |alert|
  alert.action { a(href: mappings_path) { "Fix the mappings" } }
  "Archived capability “Systems thinking” has no migration mapping."
end

render Components::Kit::EmptyState.new(title: "No frameworks yet") do |empty|
  empty.action { a(href: new_framework_path) { "Create a framework" } }
  "A framework sets out the roles, levels and capabilities people are rated on."
end
```

- **`Kit::Alert`**: a message in the page. `emphasis: :subtle` (the default) or `:solid`; `dismissible: true` adds a ×. Danger is announced at once; other tones politely.
- **`Kit::Toast`**: an alert that floats and removes itself, inside a `Kit::Toast::Stack`. The layout renders flash messages this way.
- **`Kit::EmptyState`**: what a list shows before it has anything. `size: :panel` for a side panel or card.

### Layout and content

```ruby
render Components::Kit::Card.new(title: "People", href: tenant_users_path) do |card|
  card.body { "Invite and manage people." }
end

render Components::Kit::SectionHeading.new("Capabilities", subtitle: "36 across 25 roles") do |heading|
  heading.action { a(href: "#") { "View all" } }
end
```

- **`Kit::Card`**: `variant: :flush` drops the body padding (for a table), `:inset` is a panel inside another surface. `density: :compact` tightens it. `href:` makes the whole card a link, so it can't hold other links.
- **`Kit::SectionHeading`**: a heading with an optional subtitle and action. `tag: :h3` for a lower level.
- **`Kit::DescriptionList`**: term and detail pairs in 1 to 4 columns.
- **`Kit::Prose`**: anything a person wrote (feedback, comments, notes), with its Markdown rendered and escaped. `Prose.to_plain(text)` for an excerpt.

### Forms

`Kit::Field` is class strings, not a component, because most fields come from Rails form builders:

```ruby
f.text_field :name, class: Components::Kit::Field::INPUT
f.select :level, options, {}, class: Components::Kit::Field::SELECT
f.text_field :name, class: [Components::Kit::Field::INPUT, Components::Kit::Field::INVALID], aria: { invalid: true }
```

Also `TEXTAREA`, `INLINE` (the compact in-place editors), `CHECKBOX` and `RADIO`.

### Icons

`icon(:pencil, class: "size-4")` draws a glyph from `Kit::IconSprite`, which the page layout renders once. Lookbook's icon gallery lists every name. To add one, or to add an option, slot or component, see [phlex-views.md → Extending Kit](../../docs/guidelines/phlex-views.md#extending-kit). Size and colour come from the classes you pass.

## Colour outside Kit

When a view needs colour of its own, use a **role**, never a palette step: `text-muted`, not `text-gray-600 dark:text-gray-300`. A role carries light, dark and every theme, so it needs no `dark:` partner and a theme can restyle it.

| Job | Utility |
|---|---|
| Body text, headings | `text-default` |
| Help, metadata, captions | `text-muted` |
| A link in running text | `text-link hover:text-link-hover` |
| Status text | `text-danger`, `text-success`, `text-warning`, `text-info` |
| The page | `bg-page` |
| A card or panel | `bg-default`, or `Kit::Card` |
| A quieter band inside a card | `bg-subtle`, `bg-muted` |
| Row hover | `hover:bg-hover`; on a card, `hover:bg-default-hover` |
| A divider or edge | `border-default`; fainter `border-subtle` |
| A rating, score or activity type | the domain utilities, such as `bg-rating-some` |

Three rules:

- **Strong fills belong to Kit.** A view that wants `bg-brand-strong` wants a `Kit::Button` or a solid `Kit::Alert`.
- **Kit owns radius and shadow.** Don't set either on a Kit surface. Anything else that floats uses an elevation role: `shadow-raised`, `shadow-lifted`, `shadow-overlay`, `shadow-drawer` or `shadow-modal`.
- **Selected means neutral, not brand.** Flip `aria-pressed` and let the component's classes follow.

## Themes

A tenant admin picks one under **Tenant admin → Theme**:

- **Default**, the standard Espalia look.
- **Bento**, a preset that sets every role, in both schemes, and its own font.
- **Custom**, Default with the tenant's brand colour, navbar colour and font, each in light and dark.

Components don't know which theme is on. They read roles, and the theme sets the roles. Text on a colour the tenant picks (a brand button, the navbar) comes from a contrast helper, which chooses black or white, whichever reads better. Each person picks Auto, Light or Dark under **Appearance** in the user menu.

To check a component under every theme, use Lookbook's **Theme** and **Scheme** switches (the gear above any preview). In the running app, add `?theme=bento` or `?scheme=dark` to any page (development only; `?scheme=auto` hands back to the OS). For long text, big counts and hard brand colours, seed the stress-test tenant with `bin/rails dev:seed:stress`.

## Further reading

- [`docs/guidelines/theming.md`](../../docs/guidelines/theming.md): every role, building a themed component, adding a role or a preset, and the checks.
- [`docs/guidelines/phlex-views.md`](../../docs/guidelines/phlex-views.md): how to write a component.
