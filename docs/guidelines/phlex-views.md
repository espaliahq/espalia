# Phlex Views and Kit Components

**Phlex is required for all new views and components. ERB is legacy only.**

## Rules

- All new page views MUST use Phlex (inherit from `ApplicationView`)
- All new UI components MUST use Kit pattern (inherit from `ApplicationComponent`)
- Do NOT create new ERB files — use ERB only for minor fixes to existing legacy views
- Use `view_template` method (not `template`)
- Use semantic Kit helpers: `Button()`, `Card()`, `Alert()`, `Badge()`, `Avatar()`
- Always include ARIA labels in rendered html 

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
