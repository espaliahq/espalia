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

## Synchronising Navigation Steps (NON-NEGOTIABLE)

**Always assert on the destination page before chaining another navigation.** When you `visit` a path or click a link that triggers Turbo navigation, the next interaction must wait for the destination DOM to commit. If you fire a second click immediately, on slow CI runners the click can land on a stale link that's about to be replaced — Selenium reports the click as successful but it never triggers anything, and the test fails one assertion later with a confusing "expected text on the wrong page" error.

```ruby
# WRONG — second click can be silently dropped before the index commits
visit assessments_path
click_link "Review Assessment"
assert_text "Manager Review"  # may fail: page is still the index

# WRONG — back-to-back clicks with no sync between them
click_link "Assessments"
click_link "Review Assessment"
assert_text "Manager Review"

# CORRECT — assertion on the destination page commits the navigation first
visit assessments_path
assert_text "Team Assessments"
click_link "Review Assessment"
assert_text "Manager Review"

# CORRECT — same pattern between two click_link calls
click_link "Assessments"
assert_text "Team Assessments"
click_link "Review Assessment"
```

**Key principles:**
- After `visit` or any `click_link`/`click_button` that triggers navigation, add an `assert_text`/`assert_selector`/`assert_current_path` matching content unique to the destination page **before** the next navigation
- Pick a sync target that only exists on the destination page (e.g. the page heading) — not generic chrome that's present everywhere
- Form submissions (`click_button "Save"`) followed by an assertion on the response are already safe — the assertion waits for the server round-trip

**When NOT needed:**
- When the click is a form submission and the next line already asserts on response content
- For sign-in flows that already end with `assert_current_path root_path`

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

## Default Capybara Wait Time

**Capybara's `default_max_wait_time` is 10s in this project**, set in `ApplicationSystemTestCase`. GitHub-hosted ubuntu-latest runners (no Selenium grid, 2 cores) starve Chrome's JS event loop enough that Turbo Drive round-trips can exceed even 5s under load. 10s is the floor — don't lower it or pass shorter waits to assertions unless you have a specific reason.

## Flake-Prone Click Guards (automated)

The dropped-click flake class (Selenium's synthetic pointer click / modal-handler registration silently lost on starved CI) recurs often enough that two automated guards now steer new tests toward the JS-dispatch remedies documented in the sections below:

- **RuboCop cop `SystemTests/FlakeProneClick`** (`lib/rubocop/cop/system_tests/flake_prone_click.rb`) hard-fails CI (the existing `lint` job) on the two highest-signal, lowest-false-positive patterns: a bare `accept_confirm` (use `auto_confirm`), and `find("...data-action...").click` on a Stimulus-action element (JS-dispatch it). When a flagged call is genuinely the behaviour under test, opt out inline with `# rubocop:disable SystemTests/FlakeProneClick` and a comment explaining why.
- **CodeRabbit path instructions** (`.coderabbit.yaml`) catch the fuzzier cases a static cop can't reliably detect without false positives: navigation `click_button`/`click_link` without a retry/JS-fallback wrapper, `data-turbo-confirm` form submits via click, `fill_in` of an assertion-critical field, and read-after-click races.

If you add a new JS-dispatch helper, update both the cop (if it introduces a new safe form) and the table in *Stimulus Toggle Helpers*.

## Sign-In Helper (NON-NEGOTIABLE)

**Use `sign_in_as(user)` for Devise sign-in in system test setup.** Defined in `ApplicationSystemTestCase`, it visits the form, fills email/password, clicks Log in, and re-submits once if the redirect to `root_path` doesn't land within the wait window. The duplicated `visit new_user_session_path / fill_in / click_button "Log in" / assert_current_path root_path` pattern is forbidden — that exact pattern is the most common entry-point flake (the click is dropped on a starved CI runner and every subsequent assertion fails on the still-rendered sign-in form).

```ruby
setup do
  @user = FactoryBot.create(:user, password: "password123")
  ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, user: @user, tenant: @tenant) }
  sign_in_as(@user)   # default password is TEST_PASSWORD ("password123")
end
```

## Stimulus Toggle Helpers (NON-NEGOTIABLE)

**Use purpose-specific toggle helpers instead of bare `find(...).click` for Stimulus-driven toggles.** On slow CI runners, Selenium's synthetic pointer clicks have been observed to drop silently when Chrome's JS event loop is starved or when the target is momentarily obscured (sticky element, mid-flight layout, scroll position). These helpers dispatch the click via JS (`element.click()`) instead — synchronous, bypasses pointer hit-testing, the Stimulus action handler runs inline before the script returns. The primitive (`stimulus_toggle`) re-dispatches once if the visible state never appears, gated on the toggle still being un-toggled (avoids ping-pong). It also waits for `wait_for_turbo_idle` before and after the click so a mid-flight Turbo Frame replacement can't detach the just-toggled element.

Available helpers (defined in `test/support/system/stimulus_helpers.rb`):

| Helper | Controller | Usage |
|--------|-----------|-------|
| `open_dropdown(scope:)` | dropdown | Opens a dropdown menu |
| `toggle_sidebar(scope:)` | sidebar | Opens the mobile sidebar drawer |
| `toggle_role_pane(scope:)` | framework-explorer | Opens the framework explorer role pane |
| `toggle_panel(scope:)` | panel | Opens a panel (e.g. scoring panel) |
| `expand_matrix_row(selector, scope:)` | matrix | Expands a matrix row by capability selector |
| `click_rating_frequency(cell_selector, freq)` | (rating cell) | Clicks a frequency button, retries until ring-1 lands |

```ruby
# WRONG — bare Capybara click can be silently lost on CI
wait_for_stimulus "dropdown"
find("[data-action='dropdown#toggle']").click
assert_selector "[role='menu']", visible: true

# CORRECT — helper waits for Stimulus, dispatches a JS click, asserts state
open_dropdown

# WRONG — matrix expansion without JS-dispatched click
wait_for_stimulus "matrix"
find("#capability-name-#{@cap_stable}").click
assert_selector "[data-matrix-target='expandedRow']", visible: true

# CORRECT — helper handles the full sequence
expand_matrix_row("#capability-name-#{@cap_stable}")
```

**When to use:** Any time you need to open/expand a Stimulus-controlled toggle in a system test. The helpers handle controller readiness and visibility assertions.

**When NOT needed:** When testing the *close* path (clicking to hide/collapse), since the helper asserts the element becomes visible.

**Adding new helpers:** If a new controller with toggle behavior is added, create a thin wrapper that calls the private `stimulus_toggle` primitive with the controller's specific selectors.

## Click-and-Retry for Turbo Navigation Links (NON-NEGOTIABLE)

**Use `click_with_retry` for Turbo Drive and Turbo Frame navigation links that drive cross-frame updates.** The Stimulus toggle helpers above only protect Stimulus actions. Plain `<a>` links — including those with `data-turbo-frame=...` — are equally vulnerable to silently dropped clicks on slow CI, but the existing helpers don't cover them.

```ruby
# WRONG — bare click on a Turbo Frame link can be silently dropped
within "#scoring-panel" do
  click_on "Delivering"
end
assert_text "Execution"   # may fail: matrix never re-fetched

# CORRECT — wrap the click in click_with_retry
click_with_retry(expect_text: "Execution") do
  within "#scoring-panel" do
    click_on "Delivering"
  end
end
```

**When to use:** Any click that triggers a Turbo navigation (Turbo Drive page nav, Turbo Frame fetch, or Turbo Stream broadcast) where the destination content is the only signal the click was honoured.

**When NOT needed:** When the click is on a Stimulus-controlled toggle (use the toggle helpers above) or when the click is a form submission already followed by an `assert_text` on the response (the form submit already round-trips).

**Both attempts dropped — use the JS-fallback helpers.** `click_with_retry` retries the same Capybara mechanism, so when Chrome's event loop stays starved across both yields, both attempts can be lost on the same run. For the highest-traffic navigation links (sign-in flows, "Define new cycle", "Test Framework", "Review Assessment", "Save settings", etc.) prefer:

| Helper | Replaces |
|--------|----------|
| `click_link_with_js_fallback(locator, expect_text:)` | `click_with_retry { click_link "..." }` |
| `click_button_with_js_fallback(locator, expect_text:)` | `click_with_retry { click_button "..." }` |

These do one Capybara click, and if the destination text/selector doesn't appear within 8s, dispatch a synchronous `el.click()` via `execute_script` — bypasses Selenium pointer hit-testing entirely so the second attempt is guaranteed to fire.

## Confirm Dialogs: Auto-Confirm Over Accept-Confirm (NON-NEGOTIABLE)

**Use `auto_confirm { ... }` for Turbo `data-turbo-confirm` form submissions where the test cares about the action, not the dialog text.** Capybara's `accept_confirm` registers a modal handler then yields the click block, then waits for the dialog. On slow CI, the click can fire before the modal handler is fully registered — the dialog appears, fires `confirm()` instantly with no listener, and is gone before Capybara polls. Even with retry, this can fail repeatedly because each attempt re-races the same registration window.

`auto_confirm` stubs `window.confirm` to return `true` before the click, so Turbo's submit-listener resolves the confirm synchronously without ever opening a dialog. Wrap it in `click_with_retry` to also retry the click itself if dropped:

```ruby
# WRONG — accept_confirm flakes on starved CI even with retry
accept_confirm(/Starting alignment will lock/) { click_button "Start alignment" }

# CORRECT — auto-confirm + click retry
click_with_retry(expect_text: "Aligning") do
  auto_confirm { click_button "Start alignment" }
end
```

**When NOT to use:** When the dialog's text/behaviour is itself under test. Then keep `accept_confirm` and pay the flake cost knowingly (or write the assertion at the integration test layer).

## Inline-Editor Form Submits — `requestSubmit()` Over Click

**Submit inline-editor forms via `form.requestSubmit()` not Capybara button click.** The inline-editor pattern (illustration save, capability rename, etc.) uses a hover-revealed Save button. On slow CI the button click is silently dropped repeatedly — even `click_with_retry`'s second attempt has been observed to drop. Invoking the form's submit method synchronously via JS bypasses pointer hit-testing entirely and Turbo's submit interceptor fires every time:

```ruby
# WRONG — pointer click can be dropped, retry uses same mechanism
ill_li.find("button[type='submit']", match: :first).click
assert_text "Proactively seeks guidance"

# CORRECT — synchronous form submit via JS
page.execute_script("arguments[0].querySelector('form').requestSubmit();", ill_li)
assert_text "Proactively seeks guidance"
```

This is the same primitive the suite already uses for the inline-editor display↔form toggle.

## Click-Outside Listeners Need a Real `MouseEvent`

**Dispatch outside-click events via `execute_script` with a constructed `MouseEvent`, not Selenium's pointer or `find(...).click`.** stimulus-use's `useClickOutside` registers a window capture-phase click listener. Selenium's synthetic pointer events do not reliably trigger that listener under headless Chrome load — the dropdown/sidebar/overlay never closes:

```ruby
# WRONG — synthetic pointer click misses the window capture-phase listener
find("main").click

# CORRECT — JS-dispatched MouseEvent bubbles to the window listener
page.execute_script(<<~JS)
  document.querySelector("main").dispatchEvent(
    new MouseEvent("click", { bubbles: true, cancelable: true, view: window })
  )
JS
```

## Waiting for Lazy-Loaded Turbo Frames (NON-NEGOTIABLE)

**When a page eager-loads Turbo Frames via `src:` and inner-content fallback, wait for those frames to finish their fetch before clicking inside them.** The fallback content is rendered immediately, but Turbo replaces it once the `src` fetch completes. A click between initial render and replacement can hit a stale link about to be removed from the DOM.

Turbo Frames carry a `complete` attribute after their first successful load. Assert on it before interacting with content inside the frame:

```ruby
# WRONG — clicking inside a lazy-loaded frame before its eager fetch lands
visit assessment_path(@assignment)
within "#scoring-panel" do
  click_on "Delivering"
end

# CORRECT — wait for the frame's first load to complete
visit assessment_path(@assignment)
assert_selector "turbo-frame#assessment-scoring[complete]", visible: :all
within "#scoring-panel" do
  click_on "Delivering"
end
```

**When to use:** Any time the test interacts with content inside a `turbo_frame_tag(name, src: ..., data: ...) do ... end` block on a page where the frame's eager-loaded `src` will replace the inline fallback.

**When NOT needed:** Frames without `src:` (eager-rendered only) or frames whose inner content is already verified by an earlier `assert_text` on something only the loaded version would render.

## Stimulus-Driven UI in System Tests (NON-NEGOTIABLE)

**Always assert visibility after triggering Stimulus actions before interacting with the resulting DOM.** Elements toggled by Stimulus controllers (dropdowns, modals, expanded rows) exist in the DOM as hidden elements. Capybara's `find` and `within` will locate hidden elements and fail — or worse, pass locally but fail on slower CI runners due to race conditions.

```ruby
# WRONG — within finds the hidden [role='menu'] before Stimulus opens it
find("[data-action='dropdown#toggle']").click
within("[role='menu']") do
  click_on "Sign out"
end

# CORRECT — use the toggle helper, then interact with the revealed element
open_dropdown
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
  click_button "Consistently"
end

# CORRECT — single find + click resolves the element at click time
find("#rating-#{@cap1_stable}-1 button", text: "Consistently").click
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
