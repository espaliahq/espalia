# CLAUDE.MD

Reusable AI coding guidelines for a modern Rails 8 application with Hotwire, Phlex, TailwindCSS v4, and PostgreSQL.

## System Overview

This is an open-source, multi-tenant platform for operationalising career growth frameworks, built with **Rails 8** and **RailsEventStore (RES)**. Organisations define career paths — role families, roles, levels, capabilities, and behavioural expectations — and use the platform to run self-assessments, manager alignment conversations, evidence collection, and growth planning.

The system embodies the philosophy that **performance is multi-dimensional and culture is the sum of consistently demonstrated behaviours**. Career paths serve as a cultural blueprint (what behaviours to reward), a performance map (what good looks like at each level), and a development roadmap (how to grow within or across roles).

## Guidance Files

This project uses a layered guidance system:

1. **CLAUDE.md** (this file) - Development commands and architecture overview
2. **Cursor Rules** (`.cursor/rules/*.mdc`) - Technology-specific standards

When in doubt, by order of precedence.

## Architecture

Four domain aggregates — two event-sourced via RES, two standard ActiveRecord:

**Event-sourced (RailsEventStore + AggregateRoot):**

- **Framework** — The career path blueprint. One RES stream per framework (`tenant-{id}/Framework-{id}`). Contains roles, capabilities, expectations, illustrations, versioning, and collaborative editing via inline suggested edits. Produces two projections: a published view (what everyone sees) and a draft/editor view (includes pending structural changes and inline suggestions).

- **Person Development** — One RES stream per person per framework (`tenant-{id}/PersonDev-{person_id}-{framework_id}`). The unified development journey — evidence, self-ratings, manager ratings, alignment conversations, growth plans, focus areas, and check-ins in one stream. An "assessment" is a projection. An "alignment agreement" is a formalising event.

**State-based (standard ActiveRecord):**

- **Tenant** — Organisation configuration, SSO, HRIS sync config, notification preferences.
- **Person** — Org chart entity (name, email, role, level, manager). Often synced from HRIS.

**Authentication entity (Devise, separate from domain):**

- **User** — Authentication identity. Has credentials, sessions, Devise modules. Linked to a Person via optional `person_id`. Not every Person has a User (HRIS imports). Not every User has a Person (tenant admins).

## Multi-tenancy

Uses `acts_as_tenant` with row-level `tenant_id` isolation on all tenant-scoped ActiveRecord models (Person, User, all projection read models, FrameworkTemplate when tenant-authored).

The RES event store tables (`event_store_events`, `event_store_events_in_streams`) are NOT managed by acts_as_tenant. Tenant isolation in the event store is achieved via **tenant-namespaced stream names**: `tenant-{tenant_id}/Framework-{framework_id}`. Stream names are always constructed via `EventStreamNaming` helper — never built by hand.

Event handlers (projections) set tenant context from event metadata before touching any ActiveRecord read models:

```ruby
ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
  # update projection read models — acts_as_tenant scoping is active
end
```

## Key Domain Concepts

**Two-layer expectations:** `BehaviouralExpectation` (one per Capability × Level) is the canonical definition people are rated against. `RoleIllustration` (multiple per Capability × Role × Level) provides clarifying examples — NOT separately rated.

**Capability scoping via bindings:** `CapabilityRoleBinding` ties a capability to a role with `weight` and `requirement_type` (`must_have` | `flexible`). No category-level scope — bindings are the source of truth.

**stable_id:** UUID linking the "same" concept across framework versions. Enables trend analysis and evidence continuity across framework evolution.

**Framework versioning:** Single event stream. Draft phase bracketed by `DraftVersionStarted` / `FrameworkVersionPublished` events. Published projection skips structural events during draft. Editorial changes (suggested edits) flow independently and apply immediately.

**Suggested edits:** Atomic, inline suggestions (Google Docs style). Three review tiers: illustrations (light), capability descriptions (moderate), canonical expectations (high). Applied immediately on approval.

**Assessment migration:** On new version publish, person development streams receive `FrameworkVersionMigrated`. Ratings migrate per mapping rules. Nothing silently dropped — archived capabilities surface for relink/dismiss.

## Project Structure

```
app/
├── models/                          # State-based ActiveRecord
│   ├── tenant.rb                    # acts_as_tenant root
│   ├── person.rb                    # acts_as_tenant :tenant
│   ├── user.rb                      # Devise + acts_as_tenant :tenant
│   └── application_record.rb
│
├── contexts/                        # Domain bounded contexts (RES)
│   ├── frameworks/
│   │   ├── events/                  # RES event classes
│   │   ├── commands/                # Command objects
│   │   ├── aggregate.rb             # include AggregateRoot
│   │   ├── command_handler.rb
│   │   └── projections/             # Synchronous read model builders
│   │
│   ├── person_development/
│   │   ├── events/
│   │   ├── commands/
│   │   ├── aggregate.rb
│   │   ├── command_handler.rb
│   │   └── projections/
│   │
│   └── reporting/                   # Cross-stream read models
│
├── read_models/                     # ActiveRecord models for projections
│   ├── framework_state/             # Published framework tables
│   ├── assessment_state.rb
│   ├── growth_plan_state.rb
│   └── reporting/
│
├── integrations/                    # HRIS, notifications, SSO adapters
│
└── controllers/
    └── api/v1/                      # JSON API
```

## Design Documents

- `docs/01-architecture-and-design.md` — Full architecture, ADRs, aggregate definitions, event schemas, Rails implementation patterns
- `docs/02-glossary.md` — Domain and technical term definitions
- `docs/03-entity-relationships.mermaid` — ERD across all aggregates
- `docs/04-event-flow.mermaid` — Domain event flow between aggregates
- `docs/05-framework-structure.mermaid` — Two-layer expectation model
- `docs/06-person-development-timeline.mermaid` — Worked example of person development events
- `docs/07-versioning-flow.mermaid` — Framework versioning in event-sourced model

## Deployment Model

Open-source core runs standalone with Postgres + Solid Queue. Optional SaaS control plane (not open-source) wraps the core with tenant provisioning, billing, and managed SSO routing. Domain modules must never depend on SaaS infrastructure.

## V1 Integrations

- **HRIS sync** (HiBob, BambooHR) — pluggable adapter pattern, creates/updates Person records
- **Notifications** (Slack, Teams, email) — noticed, RES async handlers via Solid Queue, outbox pattern
- **SSO/SAML** — Devise + OmniAuth, tenant-level SSO config

## Development Commands

```bash
bin/setup                    # Install dependencies and setup database
bin/dev                      # Start development server (Overmind/Foreman)
bin/rails server             # Standard Rails server only

bin/rails db:prepare         # Setup database (creates, migrates, seeds)
bin/rails db:migrate         # Run migrations
bin/rails db:seed            # Seed database

bin/rails test               # Run test suite (Minitest) - DO NOT pipe output
bin/rails test:system        # Run system tests (Capybara + Selenium)
SCREENSHOTS=1 bin/rails test test/system/foo.rb  # Capture screenshots per action -> saves to tmp/screenshots/{TestClass}/{test_name}/{001_action.png} -> use /screenshot-test skill to run + visually examine results

bin/rubocop                  # Run RuboCop linter
bin/rubocop -a               # Auto-fix RuboCop issues
```

> **CRITICAL**: Do NOT pipe test output (e.g. `bin/rails test | cat`). Run test commands directly.

## Core Principles

### The Rails Way

Follow standard Rails conventions - avoid unnecessary abstractions:

- **Skinny controllers**: Delegate business logic to models
- **Fat models**: Use concerns for shared behavior, callbacks for lifecycle hooks
- **Scopes**: Reusable query logic belongs in model scopes
- **Validations**: Data integrity via ActiveRecord validations and custom validators
- **Avoid service objects**: Prefer model methods and concerns. Only use service objects for truly complex cross-model orchestration
- **Background jobs**: Use SolidQueue for async work (not service wrappers)
- **Concerns and modules**: Use for shared functionality and code organization

### Ruby Style

- 2 spaces for indentation, snake_case for variables/methods
- Use `class Module::ClassName` instead of nested module/class definitions
- Add YARD documentation to all public methods and classes
- Use `frozen_string_literal: true` magic comment

```ruby
# Good
class Api::V1::UsersController < ApplicationController; end

# Bad - nested modules
module Api
  module V1
    class UsersController < ApplicationController; end
  end
end
```

## Controller Standards

- Add HTTP verb and path comments above each action: `# GET /categories`
- Use `params.expect(:resource)` instead of `params.require`
- Use `status: :see_other` for redirects after DELETE
- Use `status: :unprocessable_content` for failed creates/updates (RFC 9110)
- Use `pagy` for pagination
- Use `before_action` for common setup
- Namespace API controllers under `Api::V1`
- Use `respond_to` for format handling (HTML/JSON)
- Handle not found: `rescue ActiveRecord::RecordNotFound`

```ruby
class CategoriesController < ApplicationController
  before_action :set_category, only: [:show, :edit, :update, :destroy]

  # GET /categories
  def index
    @pagy, @categories = pagy(Category.sort_by_params(params[:sort], sort_direction))
  end

  # POST /categories
  def create
    @category = Category.new(category_params)
    if @category.save
      redirect_to @category, notice: "Created."
    else
      render :new, status: :unprocessable_content
    end
  end

  # DELETE /categories/:id
  def destroy
    @category.destroy
    redirect_to categories_path, status: :see_other, notice: "Deleted."
  end

  private

  def set_category
    @category = Category.find(params.expect(:id))
  end

  def category_params
    params.expect(category: [:name, :description])
  end
end
```

## Model Standards

- Define constants at the top of the file
- Use positional arguments in enums: `enum status: [:draft, :published]`
- Use `normalizes` for attribute normalization
- Use `attribute` declarations for strong typing with defaults
- Use `store_accessor` for simple key-value JSON columns
- Use `store_model` for complex structured objects in JSONB columns
- Use `counter_cache` for belongs_to relationships that need counts
- Pass models to jobs, not IDs (they are serialized automatically)
- **Slugs must use dashes, not underscores**: `"climate-action"` not `"climate_action"`

```ruby
class Plan < ApplicationRecord
  INTERVALS = [:month, :year].freeze

  store_accessor :details, :features

  attribute :currency, default: "usd"
  normalizes :currency, with: ->(c) { c.downcase }

  validates :name, :amount, :interval, presence: true
  validates :interval, inclusion: { in: INTERVALS }

  scope :visible, -> { where(hidden: [nil, false]) }
  scope :monthly, -> { where(interval: :month) }
  scope :sorted, -> { order(amount: :asc) }

  # Returns formatted features list
  # @return [Array<String>]
  def features
    Array.wrap(super)
  end
end
```

### UUID v7 Primary Keys

All new models use UUID v7 (RFC 9562) as primary keys. Time-ordered for better database index performance than random UUID v4.

```ruby
# Migration
class CreateWidgets < ActiveRecord::Migration[8.0]
  def change
    create_table :widgets, id: :uuid do |t|
      t.references :user, type: :uuid, foreign_key: true
      t.string :status, null: false
      t.timestamps
    end
  end
end

# Model
class Widget < ApplicationRecord
  has_prefix_id :wgt  # Human-readable prefixed IDs for APIs

  belongs_to :user
  validates :status, presence: true
end
```

Generate manually: `SecureRandom.uuid_v7`

### JSONB Storage Patterns (Decision Guide)

| Pattern | Use When | Example |
|---------|----------|---------|
| `store_accessor` | Simple key-value pairs, flat structure | Theme preference, boolean flags |
| `json_translate` | User-facing text needing i18n | Names, titles, descriptions |
| `store_model` | Complex nested objects with validations | Address, configuration, metadata |

**store_accessor** - simple key-value:
```ruby
# Migration: t.jsonb :preferences, default: {}, null: false
store_accessor :preferences, :theme, :notifications_enabled
```

**json_translate** - translatable user-facing text:
```ruby
# Migration: t.jsonb :name_translations, default: {}, null: false
translates :name, :description
validates :name, presence: true

# Usage:
record.name = "Hello"           # Sets for current locale
record.name_en = "Hello"        # Sets for English
record.name_he = "Shalom"       # Sets for Hebrew
```

**store_model** - complex structured objects:
```ruby
# app/models/shipping_address.rb
class ShippingAddress
  include StoreModel::Model

  attribute :street, :string
  attribute :city, :string
  attribute :postal_code, :string

  validates :street, :city, presence: true

  def full_address
    [street, city, postal_code].compact.join(", ")
  end
end

# Parent model
class Order < ApplicationRecord
  attribute :shipping_address, ShippingAddress.to_type
  validates :shipping_address, store_model: true

  # For arrays:
  attribute :line_items, OrderLineItem.to_array_type
end
```

**When NOT to use store_model:**
- Simple key-value pairs -> Use `store_accessor`
- User-facing text needing i18n -> Use `json_translate`
- Data that could be normalized -> Create proper associations/tables
- Frequently queried fields -> Use regular columns with indexes

## Phlex Views and Kit Components

All new views MUST use Phlex. ERB is for legacy views only.

### Structure

- Page views inherit from `ApplicationView` in `app/views/`
- UI components use Kit pattern, inherit from `ApplicationComponent` in `app/components/kit/`
- Use `view_template` method (not `template`)
- Use semantic helpers: `Button()`, `Card()`, `Alert()`, `Badge()`, `Avatar()`

### Page View Pattern

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
        card.actions do
          Button("View All", variant: :link, href: activities_path)
        end
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

### Kit Component Pattern

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
      merge_attributes(
        { type: "button", class: VARIANTS[@variant] },
        @attributes
      )
    end
  end
end
```

### Controller Rendering

```ruby
class DashboardController < ApplicationController
  def show
    render Views::Dashboard::ShowView.new(user: current_user, stats: @stats)
  end
end
```

### ERB Bridge (Legacy Views Only)

When updating existing ERB views, use Kit helpers:
```erb
<%= kit_button "Save", variant: :primary %>
<%= kit_card(title: "Settings") { render "form" } %>
<%= kit_alert "Success!", variant: :success %>
```

## JavaScript & Stimulus

- Use ES6 syntax (arrow functions, destructuring)
- Add usage examples in controller header comments
- Define `static targets`, `static values`, `static classes` at top
- Use `connect()` for initialization, `disconnect()` for cleanup
- Prefer toggling classes over direct DOM manipulation
- Use `tailwindcss-stimulus-components` for common UI (Modal, Dropdown, Tabs)

### Server Requests (NON-NEGOTIABLE)

**Always use `@rails/request.js`** for fetch requests from Stimulus controllers. Never use raw `fetch()` with manual CSRF token handling.

```javascript
// WRONG - fragile, breaks in test and devcontainer environments
fetch("/endpoint", {
  method: "PATCH",
  body: JSON.stringify({ key: value }),
  headers: {
    "X-CSRF-Token": document.querySelector("[name='csrf-token']").content,
    "Content-Type": "application/json"
  }
})

// CORRECT - handles CSRF, cookies, and headers automatically
import { patch } from "@rails/request.js"

const response = await patch("/endpoint", {
  body: JSON.stringify({ key: value }),
  contentType: "application/json"
})
```

Available methods: `get`, `post`, `put`, `patch`, `destroy` from `@rails/request.js`.

### Stimulus Controller Pattern

```javascript
// Example usage:
// <div data-controller="tooltip" data-tooltip-content-value="Hello"></div>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    content: String,
    placement: { type: String, default: "top" },
    offset: { type: Number, default: 6 }
  }

  connect() {
    this.setup()
  }

  disconnect() {
    this.cleanup()
  }
}
```

## TailwindCSS v4

### Key Differences from v3

- **CSS-first configuration**: Use `@theme` directive in CSS, not `tailwind.config.js`
- **Import syntax**: `@import "tailwindcss"` instead of `@tailwind` directives
- **CSS variables for tokens**: All design tokens available as CSS variables (`--color-blue-500`, `--spacing-4`)
- **Dynamic spacing**: Every multiple of `--spacing: 0.25rem` works (e.g. `mt-21`)
- **No plugins needed**: Container queries built-in

```css
@import "tailwindcss";

@theme {
  --font-display: "Satoshi", "sans-serif";
  --color-brand-500: oklch(0.84 0.18 117.33);
}
```

### Renamed Utilities (v3 -> v4)

- `shadow-sm` -> `shadow-xs`, `shadow` -> `shadow-sm`
- `rounded-sm` -> `rounded-xs`, `rounded` -> `rounded-sm`
- `blur-sm` -> `blur-xs`, `blur` -> `blur-sm`
- `bg-opacity-*` -> Use `bg-black/50` syntax instead
- `outline-none` -> `outline-hidden` (for old behavior)
- CSS variables in arbitrary values: `bg-(--brand-color)` not `bg-[--brand-color]`

### UI Requirements

- Make all views responsive with breakpoints (sm:, md:, lg:, xl:, 2xl:)
- Add dark mode support (dark: prefix)
- Implement proper ARIA attributes for accessibility
- Use `dom_id` for HTML element IDs

## Testing

### Framework

- **Minitest** with Shoulda + FactoryBot for new tests
- Use `assert_nil` for nil expectations (not `assert_equal nil, value`)
- Do NOT pipe test output

### Visual Verification with Screenshots

System tests support automatic screenshot capture via `SCREENSHOTS=1`. Use the `/screenshot-test` skill to run system tests and visually examine every captured screenshot. This is useful for verifying UI changes, debugging layout issues, or reviewing multi-step flows. **CRITICAL** Make sure to use it to verify new or modified functionality that touches the front end!

### New Test Pattern

```ruby
class UserTest < ActiveSupport::TestCase
  subject { build(:user) }

  context "validations" do
    should validate_presence_of(:email)
    should validate_uniqueness_of(:email).case_insensitive
  end

  context "associations" do
    should have_many(:posts).dependent(:destroy)
  end

  context "when archived" do
    subject { build(:user, archived_at: Time.current) }

    should "not be active" do
      assert_not subject.active?
    end
  end

  context "#full_name" do
    should "return first and last name" do
      user = build(:user, first_name: "John", last_name: "Doe")
      assert_equal "John Doe", user.full_name
    end
  end
end
```

### Test Locations

| Type | Location | Framework |
|------|----------|-----------|
| Models | `test/models/` | Minitest + Shoulda |
| Controllers | `test/controllers/` | ActionDispatch::IntegrationTest |
| System | `test/system/` | Capybara + Selenium |
| Components | `test/components/` | ComponentTestCase |

### Component Testing

```ruby
class Kit::ButtonTest < ComponentTestCase
  context "Kit::Button" do
    should "render a button with label" do
      html = render_component(Kit::Button.new("Save"))
      assert_selector html, "button", text: "Save"
    end

    should "render with primary variant by default" do
      html = render_component(Kit::Button.new("Save"))
      assert_selector html, "button.btn.btn-primary"
    end
  end
end
```

### Testing store_model Objects

Test store_model objects with both unit tests (for the store_model class) and integration tests (for the parent model):

```ruby
# Unit test the store_model class
class ShippingAddressTest < ActiveSupport::TestCase
  subject { ShippingAddress.new(street: "123 Main St", city: "Portland") }

  context "validations" do
    should validate_presence_of(:street)
    should validate_presence_of(:city)
  end
end

# Integration test the parent model
class OrderTest < ActiveSupport::TestCase
  context "shipping_address attribute" do
    should "validate nested address" do
      order = build(:order)
      order.shipping_address = ShippingAddress.new(street: nil, city: "Seattle")
      assert_not order.valid?
    end
  end
end
```

## Service Object Standards (When Needed)

Only use for complex cross-model orchestration. Prefer model methods and concerns.

- Name with verb + noun ending with "Service" (e.g., `CreateUserService`)
- Use `class Service::ClassName` (not nested modules)
- Accept parameters via `initialize`
- Implement a `run` (or `call`) method
- Return a result object or expected return value
- Include YARD documentation
- Wrap multi-model operations in transactions

```ruby
class CreateUserService
  # @param attributes [Hash] User attributes
  # @return [User] The created user
  def initialize(attributes)
    @attributes = attributes
  end

  def run
    User.transaction do
      @user = User.create!(@attributes)
      create_defaults
    end
    @user
  end

  private

  def create_defaults
    # ...
  end
end
```

## Key Directories

```
app/
  components/kit/          # Phlex Kit components (Button, Card, Alert, etc.)
  controllers/             # Rails controllers (skinny)
  jobs/                    # Background jobs (SolidQueue)
  models/                  # Fat models with concerns
  models/concerns/         # Shared model modules
  policies/                # Pundit authorization policies
  views/                   # Phlex page views (new) + ERB (legacy)

config/
  routes/                  # Modular route definitions

test/
  models/                  # Model tests
  controllers/             # Controller integration tests
  system/                  # System tests (Capybara)
  components/              # Component unit tests
```

## Technology Stack

- **Rails 8** with Hotwire (Turbo + Stimulus)
- **PostgreSQL** with UUID v7 primary keys, JSONB columns
- **RailsEventStore (RES) ~> 2.16+** — Event store, aggregate roots, projections, event subscriptions
- **SolidQueue** (jobs), **SolidCache** (cache), **SolidCable** (websockets)
- **Import Maps** for JavaScript (no Node.js dependency)
- **TailwindCSS v4** via tailwindcss-rails gem
- **Phlex 2.x** for views and components
- **Devise** for authentication
- **Pundit** for authorization
- **Minitest** with Shoulda + FactoryBot for testing
- **store_model** for typed JSONB columns
- **json_translate** for model translations
- **has_prefix_id** for human-readable API IDs
- **pagy** for pagination
- **@rails/request.js** for Stimulus fetch requests

## Quick Reference

| Task | Pattern |
|------|---------|
| New model | UUID v7: `create_table :x, id: :uuid` |
| API-facing ID | `has_prefix_id :prefix` |
| New view | Phlex in `app/views/resource/action_view.rb` |
| New component | Kit in `app/components/kit/component_name.rb` |
| Business logic | Model methods or concerns (not services) |
| Async work | Background job in `app/jobs/` |
| New test | Shoulda + FactoryBot |
| Authorization | Pundit policy in `app/policies/` |
| Translatable text | `jsonb :attr_translations` + `translates :attr` |
| Complex JSON | `store_model` with type-safe models |
| Simple JSON | `store_accessor` for flat key-value |
| Slugs | Always use dashes: `"my-slug"` not `"my_slug"` |
| Stimulus fetch | `@rails/request.js` (never raw `fetch`) |
| Pagination | `pagy` |
| Nil assertions | `assert_nil value` (not `assert_equal nil, value`) |
