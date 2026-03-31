# Testing Standards

## Framework

- **Minitest** with Shoulda Matchers + FactoryBot
- These patterns apply to **new tests only** — do not rewrite existing tests
- Do NOT pipe test output: run `bin/rails test` directly, never `bin/rails test | cat`
- Use `assert_nil value` (not `assert_equal nil, value`)

## Test Locations

| Type | Location | Base Class |
|------|----------|------------|
| Models | `test/models/` | `ActiveSupport::TestCase` |
| Controllers | `test/controllers/` | `ActionDispatch::IntegrationTest` |
| Policies | `test/policies/` | `ActiveSupport::TestCase` |
| System | `test/system/` | `ApplicationSystemTestCase` |
| Components | `test/components/` | `ComponentTestCase` |

## New Test Pattern (Shoulda + FactoryBot)

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

## Component Testing

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

## Testing store_model Objects

Test the store_model class directly AND integration via the parent model:

```ruby
# Unit test the store_model class
class ShippingAddressTest < ActiveSupport::TestCase
  subject { ShippingAddress.new(street: "123 Main St", city: "Portland") }

  context "validations" do
    should validate_presence_of(:street)
    should validate_presence_of(:city)
  end
end

# Integration test via parent model
class OrderTest < ActiveSupport::TestCase
  context "shipping_address" do
    should "validate nested address" do
      order = build(:order)
      order.shipping_address = ShippingAddress.new(street: nil, city: "Seattle")
      assert_not order.valid?
    end
  end
end
```

## Policy Testing (NON-NEGOTIABLE)

**Every Pundit policy MUST have corresponding tests.** New controller actions require both a policy test (unit) and a controller test for the denied-access path.

Policy tests build an `AuthorizationContext` and assert permit/deny per role:

```ruby
class FrameworkPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @framework = create(:framework_state_framework, tenant: @tenant)
  end

  context "as tenant member" do
    setup do
      @user = create(:user)
      @tenant_user = create(:tenant_user, user: @user, tenant: @tenant, role: :member)
      @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: nil)
    end

    should "permit show" do
      assert FrameworkPolicy.new(@context, @framework).show?
    end

    should "deny settings" do
      assert_not FrameworkPolicy.new(@context, @framework).settings?
    end
  end

  context "as tenant admin" do
    setup do
      @tenant_user = create(:tenant_user, tenant: @tenant, role: :admin)
      @context = AuthorizationContext.new(
        user: @tenant_user.user, tenant_user: @tenant_user, person: nil
      )
    end

    should "permit settings" do
      assert FrameworkPolicy.new(@context, @framework).settings?
    end
  end
end
```

### What to test per policy

- **Non-member** (no TenantUser) → denied everything
- **Tenant member** → can view, cannot admin
- **Tenant admin** → full access
- **Person (self)** → can self-rate, view own assessment
- **Manager** → can view/rate direct report's assessment, cannot self-rate for them
- **Framework collaborator roles** → edit rights per role, publish rights for owner/editor only

### Controller denied-access tests

Every controller test file must include at least one denied-access scenario:

```ruby
context "as non-admin member" do
  should "redirect from settings" do
    sign_in @member_user
    get framework_settings_path(@framework)
    assert_redirected_to root_path
    assert_equal "You are not authorized to perform this action.", flash[:alert]
  end
end
```

### System tests for auth-gated UI

Test that restricted UI elements (buttons, links, admin panels) do not appear for unauthorized roles:

```ruby
should "not show settings link for non-admin" do
  sign_in_as(@member_user)
  visit framework_path(@framework)
  assert_no_selector "a", text: "Settings"
end
```

## Visual Verification with Screenshots

System tests support automatic screenshot capture via `SCREENSHOTS=1`. Use the `/screenshot-test` skill to run system tests and visually examine every captured screenshot. **Use this to verify any new or modified front-end functionality.**

```bash
SCREENSHOTS=1 bin/rails test test/system/foo.rb
# Screenshots saved to: tmp/screenshots/{TestClass}/{test_name}/{001_action.png}
```

## Responsive Behaviour Testing (NON-NEGOTIABLE)

**Every responsive behaviour must have a corresponding system test at both desktop and mobile viewports.** If a feature behaves differently at different breakpoints (hidden/shown, sidebar vs. overlay, collapsed vs. expanded), test both states.

Use viewport constants and `resize_to` before visiting pages:

```ruby
DESKTOP_SIZE = [1400, 1400].freeze
MOBILE_SIZE  = [375, 812].freeze

should "show role tree inline on desktop" do
  page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
  visit framework_path(@framework_id)
  assert_selector "[data-framework-explorer-target='rolePane']", visible: true
end

should "show role tree as overlay on mobile after toggle" do
  page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
  visit framework_path(@framework_id)
  assert_no_selector "[data-framework-explorer-target='rolePane']", visible: true
  click_button "Roles"
  assert_selector "[data-framework-explorer-target='rolePane']", visible: true
end
```

**Key principles:**
- Reset viewport in `setup` (browser window persists across tests)
- Test both the hidden-by-default state AND the toggle interaction
- Use `visible: true` / `visible: :all` appropriately — `visible: true` checks CSS visibility, `:all` finds hidden DOM elements
- Use `SCREENSHOTS=1` to visually verify responsive layouts at both sizes

## Waiting for Stimulus Controllers (NON-NEGOTIABLE)

**Use `wait_for_stimulus` before interacting with Stimulus-controlled UI.** Stimulus controllers that extend `BaseController` set a `data-connected` attribute when connected. On slow CI runners, clicking before the controller connects means action handlers aren't attached yet — the click does nothing and the test flakes.

```ruby
# WRONG — clicks before the matrix controller may have connected
visit assessment_path(@framework_id)
find("[data-matrix-target='row']", match: :first).click
# May silently do nothing on CI

# CORRECT — waits for the controller to connect first
visit assessment_path(@framework_id)
wait_for_stimulus "matrix"
find("[data-matrix-target='row']", match: :first).click
assert_selector "[data-matrix-target='expandedRow']", visible: true
```

**When to use:**
- After `visit` or any Turbo navigation, before clicking elements that rely on Stimulus actions
- The argument is the controller name (e.g. `"matrix"`, `"dropdown"`, `"framework-explorer"`)
- Optional `scope:` parameter narrows the search (e.g. `scope: "[data-framework-explorer-target='rolePaneToggle']"`)

**When NOT needed:**
- For simple links, forms, or elements that don't use Stimulus actions
- When the next assertion already waits (e.g. `assert_text` on server-rendered content)

## Stimulus-Driven UI in System Tests (NON-NEGOTIABLE)

**Always assert visibility after triggering Stimulus actions before interacting with the resulting DOM.** Elements toggled by Stimulus controllers (dropdowns, modals, expanded rows) exist in the DOM as hidden elements. Capybara's `find` and `within` will locate hidden elements and fail — or worse, pass locally but fail on slower CI runners due to race conditions.

```ruby
# WRONG — within finds the hidden [role='menu'] before Stimulus opens it
find("[data-action='dropdown#toggle']").click
within("[role='menu']") do
  click_on "Sign out"
end

# CORRECT — assert_selector waits for the element to become visible
find("[data-action='dropdown#toggle']").click
assert_selector "[role='menu']", visible: true
within("[role='menu']") do
  click_on "Sign out"
end
```

**Key principles:**
- After any click/action that triggers a Stimulus transition, add `assert_selector ..., visible: true` before interacting with the revealed element
- Use `assert_selector` (not `find`) to wait — it retries until Capybara's wait timeout
- This applies to dropdowns, modals, accordions, expanded table rows, and any element toggled via `useTransition` or class manipulation
- `within` does NOT wait for visibility — always assert visibility first

## Avoiding Stale Element References with Turbo Streams (NON-NEGOTIABLE)

**Never use `within first(...)` or `within find(...)` to scope a click inside an element that Turbo Stream may replace.** The `within` block holds a cached reference to the DOM node. If a Turbo Stream response replaces that node between the `find` and the `click_button`, Selenium raises `StaleElementReferenceError`. This passes locally but flakes on slow CI runners.

```ruby
# WRONG — first() caches the element, Turbo Stream replaces it, click_button hits a stale ref
within first("[id^='rating-']") do
  click_button "Consistent"
end

# CORRECT — single find + click resolves the element at click time
find("#rating-#{@cap1_stable}-1 button", text: "Consistent").click
```

**Key principles:**
- Use precise `#id`-based selectors rather than `first(...)` or pattern-matched selectors when the target may be replaced by Turbo Streams
- Combine `find` and `.click` in a single expression — don't cache elements in variables across Turbo Stream boundaries
- If you must use `within`, scope it to a container that is NOT replaced (e.g. the parent `tr` or a wrapper div that sits outside the Turbo Stream target)
- This applies to any element inside a Turbo Stream replacement target: rating cells, scoring panels, category headers, contribution labels

## Shared Setup Across Contexts

**When multiple contexts need the same setup (e.g. a manager identity), use a single parent context instead of duplicating the setup block.** Duplicated setup drifts apart over time, makes tests harder to maintain, and inflates the test file.

```ruby
# WRONG — duplicated setup in sibling contexts
context "GET /resources/:id as manager" do
  setup do
    @manager_user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email)
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
      @person.update!(manager: @manager)
    end
  end

  should "render manager view" do ... end
end

context "GET /resources as manager" do
  setup do
    # exact same block copied again
  end

  should "show team section" do ... end
end

# CORRECT — single parent context with shared setup
context "as manager" do
  setup do
    @manager_user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email)
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
      @person.update!(manager: @manager)
    end
  end

  should "render manager view for show" do ... end
  should "show team section on index" do ... end
  should "deny access to unrelated users" do ... end
end
```

**Key principles:**
- Group tests by identity/role (`"as manager"`, `"as tenant admin"`, `"as unrelated user"`) not by HTTP endpoint
- If two contexts share >50% of their setup, merge them
- Nested contexts inherit parent setup — use this to layer additional state

## Rules

- Use `subject { }` to define the object under test
- Use `context` blocks to group related tests
- Use `should` matchers for validations, associations, callbacks
- Use FactoryBot (`build`, `create`, `build_stubbed`) — not fixtures for new tests
- Test happy paths, sad paths, and edge cases
