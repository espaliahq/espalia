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
| Components | `test/components/` | `ActiveSupport::TestCase` |

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

Component tests are `ActiveSupport::TestCase`s that render with `#call` and read the HTML with Nokogiri. `test/components/kit/alert_test.rb` is the model:

```ruby
class Components::Kit::AlertTest < ActiveSupport::TestCase
  def render_alert(**options, &block)
    block ||= proc { "Weight must be between 0 and 10." }
    Nokogiri::HTML5.fragment(Components::Kit::Alert.new(**options).call(&block)).at_css("div")
  end

  context "Components::Kit::Alert" do
    should "colour itself only through the tone, for every tone" do
      Components::Kit::Alert::TONES.each do |tone, tone_class|
        assert_includes render_alert(tone: tone)["class"].split, tone_class
      end
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
# A namespaced class writes a dash-joined directory — AssessmentCycles::Foo
# → tmp/screenshots/AssessmentCycles-Foo/... — because upload-artifact
# rejects a colon anywhere in the path.
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
click_link "Review assessment"
assert_text "Manager Review"  # may fail: page is still the index

# WRONG — back-to-back clicks with no sync between them
click_link "Assessments"
click_link "Review assessment"
assert_text "Manager Review"

# CORRECT — assertion on the destination page commits the navigation first
visit assessments_path
assert_text "Team Assessments"
click_link "Review assessment"
assert_text "Manager Review"

# CORRECT — same pattern between two click_link calls
click_link "Assessments"
assert_text "Team Assessments"
click_link "Review assessment"
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

**Capybara's `default_max_wait_time` is 10s in this project**, set in `ApplicationSystemTestCase`. CI runners (no Selenium grid, Puma, Chrome and the test process on a few cores) starve Chrome's JS event loop enough that Turbo Drive round-trips can exceed even 5s under load. 10s is the floor — don't lower it or pass shorter waits to assertions unless you have a specific reason.

## Flake-Prone Click Guards (automated)

The dropped-click flake class (Selenium's synthetic pointer click / modal-handler registration silently lost on starved CI) recurs often enough that two automated guards now steer new tests toward the JS-dispatch remedies documented in the sections below:

- **RuboCop cop `SystemTests/FlakeProneClick`** (`lib/rubocop/cop/system_tests/flake_prone_click.rb`) hard-fails CI (the existing `lint` job) on the highest-signal, lowest-false-positive patterns: a bare `accept_confirm` (use `auto_confirm`), a bare `click_button` / `click_link` / `click_on` inside `auto_confirm` (use a JS-fallback helper), `find("...data-action...").click` on a Stimulus-action element (JS-dispatch it) — **including a scoped `row.find(...)`, which drops its click exactly like a top-level one** — and `send_keys(:escape)` / `send_keys(:tab)` (use `press_escape` / `press_tab`). When a flagged call is genuinely the behaviour under test, opt out inline with `# rubocop:disable SystemTests/FlakeProneClick` and a comment explaining why.
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

**The JS re-submit fallback fails the test loudly if the Devise form stops matching its selector** (`SIGN_IN_FORM_SELECTOR` in `test/application_system_test_case.rb`). It used to no-op silently, so a view or route change surfaced as a generic "still on the sign-in page" failure blaming the dropped click the fallback exists to recover from. A Devise change now names itself; a slow first submit that lands mid-fallback is still tolerated.

## Stimulus Toggle Helpers (NON-NEGOTIABLE)

**Use purpose-specific toggle helpers instead of bare `find(...).click` for Stimulus-driven toggles.** On slow CI runners, Selenium's synthetic pointer clicks have been observed to drop silently when Chrome's JS event loop is starved or when the target is momentarily obscured (sticky element, mid-flight layout, scroll position). These helpers dispatch the click via JS (`element.click()`) instead — synchronous, bypasses pointer hit-testing, the Stimulus action handler runs inline before the script returns. The primitive (`stimulus_toggle`) re-dispatches once if the visible state never appears, gated on the toggle still being un-toggled (avoids ping-pong). It also waits for `wait_for_turbo_idle` before and after the click so a mid-flight Turbo Frame replacement can't detach the just-toggled element.

Available helpers (defined in `test/support/system/stimulus_helpers.rb`):

| Helper | Controller | Usage |
|--------|-----------|-------|
| `open_dropdown(scope:)` | dropdown | Opens a dropdown menu |
| `toggle_sidebar(scope:)` | sidebar | Opens the mobile sidebar drawer |
| `toggle_role_pane(scope:)` | framework-explorer | Toggles the framework explorer role pane (an overlay below `lg`, an inline column above it) — it starts open on desktop, so there a call closes it |
| `toggle_context_pane(scope:)` | framework-explorer | Toggles the framework explorer activity pane — same two shapes; open by default on desktop (a call closes it), CLOSED by default below `lg` (a call opens it) |
| `toggle_panel(scope:)` | panel | Opens a panel (e.g. scoring panel) |
| `expand_matrix_row(selector, scope:, await_content:)` | matrix | Expands a matrix row by capability selector. The row's content is fetched on first expand, so the helper waits for the loaded row by default — assert on its content, not on the row; pass `await_content: false` only when the load itself is what's under test |
| `start_inline_edit(container)` | field-editor | Opens the explorer's shared inline editor via its pencil, returns the cloned form. Finds the pencil inside the host, or — for the role tree, whose pencils sit in the row's floating cluster outside the name frame — the one naming that frame with `data-editor-host-frame` |
| `open_explorer_menu(label, scope:, index:)` | explorer-menu | Opens one of the explorer grid's delegated kebab menus by its trigger's aria-label (the menu does not exist until then) |
| `click_explorer_menu_item(label, expect_text:)` | explorer-menu | Clicks an item of the OPEN explorer menu by its leading text |
| `use_explorer_menu(label, item, …)` | explorer-menu | The two above in one call |
| `submit_inline_edit(form, with:)` | field-editor | Sets the editor's textarea via JS and `requestSubmit()`s it |
| `cancel_inline_edit(form)` | field-editor | Cancels an open editor via its Cancel button |
| `open_pill_popover(cell_selector)` | dropdown | Opens an assessment rating pill's popover (JS-click fallback if the pointer click is dropped) |
| `click_rating_frequency(cell_selector, freq)` | (rating cell) | Opens the popover and picks a frequency, retrying until the pill's trigger reads that phrase (deliberately not a ring/selected class — the assertion survives styling changes) |
| `toggle_activity_pane` | activity-pane | Opens/closes the **assessment** activity sidebar by invoking the controller method directly (not the explorer's pane — that's `toggle_context_pane`) |

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

**These helpers emit `note: JS recovery —` lines too, and they mean something different here.** `stimulus_toggle` asserts the toggle exists *before* dispatching, so a dispatch that later matches nothing points at **detachment or a frame re-render** — a Turbo Frame replaced the node in one of the two `wait_for_turbo_idle` windows — not at a drifted selector. The note says which dispatch missed, so read it before assuming the selector is wrong.

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

**Both attempts dropped — use the JS-fallback helpers.** `click_with_retry` retries the same Capybara mechanism, so when Chrome's event loop stays starved across both yields, both attempts can be lost on the same run. For the highest-traffic navigation links (sign-in flows, "Define new cycle", "Test Framework", "Review assessment", "Save settings", etc.) prefer:

| Helper | Replaces |
|--------|----------|
| `click_link_with_js_fallback(locator, expect_text:)` | `click_with_retry { click_link "..." }` |
| `click_button_with_js_fallback(locator, expect_text:)` (or `expect_no_text:` when the success signal is content *disappearing* — an appearance signal already on the page can never arm the fallback) | `click_with_retry { click_button "..." }` |
| `click_selector_with_js_fallback(selector, expect_text:)` — for elements addressed by CSS selector rather than visible text (e.g. `a[data-person-id=…]` dots) | `click_with_retry { find("...").click }` |

These do one Capybara click, and if the destination text/selector doesn't appear within 8s, re-find the target and dispatch a synchronous `el.click()` from an `evaluate_script` that reports whether it found anything — bypassing Selenium pointer hit-testing entirely, so the second attempt is guaranteed to fire.

**The re-find resolves the target as Capybara does:** visible elements only, an exact label before a partial one, and no click when several match. It used to take the first partial match in the page, so a dropped click on the binding editor's "Add role" became a click on the role tree's "+ Add role". To check every locator still resolves after changing a finder, skip the first click in both helpers temporarily and run `bin/rails test:system`: only `ClickRecoveryNoteSystemTest`, which needs the real click, should fail.

**If a failure carries a `note: JS recovery —` line, read it first.** That is the shared cue for every recovery in the helpers, and the phrase after it names the cause the evidence actually supports: a drifted locator, an element rendered late, a frame re-render, a detached node, or a document replaced mid-navigation. The helpers never fail *because* of a miss (a slow first click can land after the recovery runs, so the assertion keeps its full wait); the note appears only alongside a genuine failure it is likely to explain.

**Pass exactly one signal** — exactly one of `expect_text:` or `expect_selector:` (plus `expect_no_text:`, accepted only by `click_button_with_js_fallback`), never two. Each helper (`click_with_retry` included) checks a single signal by precedence, so a second one would be silently ignored: never armed, never asserted. Passing zero or more than one raises `ArgumentError` at authoring time. When a click needs a second assertion, write it yourself after the helper returns.

## Copying to the Clipboard: Click for Real

**`navigator.clipboard.writeText` never settles without a real user gesture** in the Chromium
the suite runs in: a JS-dispatched click leaves the promise pending, even with focus and
permission granted, in Playwright's Chromium, Chrome for Testing and under Xvfb alike. So a
system test that copies clicks for real (`click_with_retry`), never through a JS-dispatch
helper, and the `clipboard` controller shows "Copied!" only once a copy succeeds, falling back
to `execCommand` when `writeText` hangs.

**A test of the copy's feedback calls `stub_clipboard_write` after the visit; a test of the
copy itself calls `remove_clipboard_api`, so the fallback runs inside the click.** The fallback
runs a second after the click and needs the click's user activation, which Chrome drops after
about five seconds. A runner busy enough to stall the page that long after the click loses the
copy and the feedback with it: a 6s stall reproduces it every time. Only CI takes this path.
The devcontainer serves the app from `http://rails-app`, which is not a secure context, so
`navigator.clipboard` is undefined there and the fallback runs at once.

## Confirm Dialogs: Auto-Confirm Over Accept-Confirm (NON-NEGOTIABLE)

**Use `auto_confirm { ... }` for Turbo `data-turbo-confirm` form submissions where the test cares about the action, not the dialog text.** Capybara's `accept_confirm` registers a modal handler then yields the click block, then waits for the dialog. On slow CI, the click can fire before the modal handler is fully registered — the dialog appears, fires `confirm()` instantly with no listener, and is gone before Capybara polls. Even with retry, this can fail repeatedly because each attempt re-races the same registration window.

`auto_confirm` stubs `window.confirm` to return `true` before the click and **leaves the stub in place** (a full-page navigation loads a fresh document that resets `window.confirm` on its own), so Turbo's confirm resolves to `true` with no dialog ever opening. Call it directly, never inside a retry wrapper:

```ruby
# WRONG — accept_confirm flakes on starved CI even with retry
accept_confirm(/Starting alignment will lock/) { click_button "Start alignment" }

# CORRECT — auto_confirm around a guarded click, which asserts the result
auto_confirm { click_button_with_js_fallback("Start alignment", expect_text: "Aligning") }
```

**The stub removes the dialog race, not the dropped click.** A bare
`click_button` inside `auto_confirm` is lost on a starved runner like any other
click, and two tests did exactly that
([#691](https://github.com/mr-yum/growth-os/issues/691)). Put a JS-fallback
helper or an `execute_script` dispatch inside the block; the cop flags a bare
`click_button` / `click_link` / `click_on` there.

**Do NOT wrap `auto_confirm` in `click_with_retry`.** It's actively harmful for a `data-turbo-method` *link* (vs. a form-submit button): Turbo invokes `confirm()` *asynchronously* there, so if anything restores the native `window.confirm` between the click and that call, a real dialog opens — and `click_with_retry` then re-clicks *into* the open dialog, raising `UnexpectedAlertOpenError` (and a downstream `NoMethodError` from Selenium's alert handling) on every retry. `auto_confirm` no longer restores the stub precisely to close this race, so `auto_confirm` on its own is reliable for both links and buttons; the retry wrapper only reopens the hole.

**When NOT to use:** When the dialog's text/behaviour is itself under test. Then keep `accept_confirm` and pay the flake cost knowingly (or write the assertion at the integration test layer).

**Better still: don't ship the dialog.** `auto_confirm` exists because
`data-turbo-confirm` is unavoidable in places, not because it is the right
affordance — a native `confirm()` can't be themed or focus-managed and has
nowhere to capture a reason. The framework explorer's illustration archive was
the last one on that surface and is now a `Kit::Modal` like every other
destructive action there (framework-explorer.md §11b), so its test drives a real
dialog instead. When you're adding a destructive action, reach for the modal
first and leave `auto_confirm` to the confirms that already exist.

## Inline-Editor Form Submits — `requestSubmit()` Over Click

**Submit inline-editor forms via `form.requestSubmit()` not Capybara button click.** The inline-editor pattern (illustration save, capability rename, etc.) uses a hover-revealed Save button. On slow CI the button click is silently dropped repeatedly — even `click_with_retry`'s second attempt has been observed to drop. Invoking the form's submit method synchronously via JS bypasses pointer hit-testing entirely and Turbo's submit interceptor fires every time.

**In the framework explorer, go through the two helpers rather than hand-rolling it.** There is now ONE editor for the whole explorer — the form is cloned from a `<template>` on the root when a pencil is clicked, so there is nothing to reveal by toggling classes and no per-entity `<form>` to `querySelector` before the click:

```ruby
# WRONG — nothing to un-hide; these targets no longer exist
page.execute_script("arguments[0].querySelector('[data-inline-editor-target=\"form\"]').classList.remove('hidden')", li)

# CORRECT — open via the pencil, then set + submit through the helpers
form = start_inline_edit(li)                       # returns the cloned [data-editor-form]
submit_inline_edit(form, with: "New illustration text")
assert_text "New illustration text"

# CORRECT — abandoning an edit
cancel_inline_edit(form)
```

The editor's own contract is `[data-editor-action]` on the host, `[data-editor-display]` on the read-mode element, `[data-editor-input]` / `[data-editor-submit]` inside the cloned form — assert on those, never on `data-controller="inline-editor"` (which now belongs only to the assessment-cycle settings frames).

## Typing Drops Characters Too — `js_fill_in` for Assertion-Critical Values

**`fill_in` types one character at a time, and starved CI runners drop keystrokes.** This is nastier than a dropped click: the field looks filled, but a debounced typeahead runs against `"Ra"` instead of `"Raj"` and the failure surfaces much later as "no matches" — nothing points back at the typing. That is exactly how the calibration participant picker failed.

`js_fill_in` assigns the value and dispatches `input` + `change`, so Stimulus controllers still fire:

```ruby
# WRONG — a dropped keystroke silently changes the query
fill_in "Participants (raters)", with: "Raj"
assert_selector "turbo-frame#participant-candidates button", text: "Raj Rater"

# CORRECT — the exact value lands
js_fill_in "Participants (raters)", with: "Raj"
```

It accepts a Capybara element, a CSS selector, or a field locator. Use it wherever the exact value is assertion-critical — typeahead queries, names asserted verbatim after save, anything a controller reads. Fields that are only submitted and never asserted (a reject reason, say) can stay on `fill_in`, which also keeps real typing exercised somewhere in the suite.

**Checkboxes lose clicks the same way: use `js_set_checkbox(locator, checked:)`.** Capybara's `check` / `uncheck` never confirm the box changed, so a dropped click saves the old value and the failure shows up after the save. The notification settings test saved Slack still on. The helper clicks through JS and asserts the new state.

## An Assertion a Dropped Click Would Also Satisfy Is Not a Test

**After a click, assert something that was NOT already true before it.** This is the failure mode behind three separate "flaky" tests on this branch, and in each case the test had never been testing its own subject:

- the tenant switcher clicked "Beta Inc" then asserted `current_path == root_path` — but the test *starts* on `root_path`;
- the theming test asserted the *absence* of the old tenant's `<style>` — absent both before the switch landed and if it never landed;
- a JS-fallback call passed `expect_selector: "body"`, so the landed-check succeeded instantly and the fallback could never arm.

All three pass when the click is silently dropped, so they only fail when something *else* drifts — which is exactly what "flaky" looks like from the outside. The fix is the same each time: pick a signal that only exists on the far side of the click (a flash, a destination-only element, a row that changed shape), and prove it bites by neutering the click and watching the assertion fail.

This applies doubly to the `expect_text:` / `expect_selector:` you hand a JS-fallback helper — a signal already on the page disarms the very fallback you added.

**The helpers now enforce this.** `assert_signal_is_a_transition!` runs before every guarded click and raises if `expect_text` / `expect_selector` is already true (or `expect_no_text` already absent), so a disarmed fallback fails loudly at authoring time instead of silently passing until CI. Arming it against the existing suite found thirteen such calls. If a click genuinely produces no visible transition, don't fake a signal — use a plain click and say in a comment why it's safe (usually: the next guarded step depends on it).

## Keys Need a Dispatched `KeyboardEvent` — `press_escape` / `press_tab`

**Use `press_escape` rather than `find("body").send_keys(:escape)`.** Stimulus binds Esc as `keydown.esc@window`, but Selenium's key dispatch needs a focused, interactable target — and once a modal opens, focus has moved *into* the dialog (the APG focus management), so keys aimed at `body` can be swallowed and the handler never runs.

The failure is silent and reads as "the modal didn't close" or "confirm was never called" — indistinguishable from a real bug, which is how two of these sat on `main` being written off as CI noise.

```ruby
# WRONG — the keydown may never reach the window listener
find("body").send_keys(:escape)

# CORRECT — construct the event and dispatch it where the listener is
press_escape
press_escape(scope: "#evm-content")   # dispatch from an element; it bubbles
```

Same principle as the `MouseEvent` rule below: dispatch the event where the listener actually is.

**A supplied `scope:` must match.** The helper resolves it with Capybara (so it waits for an element still rendering) and fails the test if it never appears — it no longer falls back to a window dispatch. That fallback was invisible and self-defeating: a window dispatch still closes the modal, so a renamed id or a modal that never opened left the test passing while proving nothing about in-dialog dispatch.

### Tab is the same rule, with a different listener — `press_tab`

**Use `press_tab` / `press_tab(shift: true)` rather than `find("body").send_keys(:tab)`.** `modal`'s focus trap decides what to do by reading `document.activeElement` — and Selenium *focuses the element it sends keys to*, so aiming keys at `body` perturbs the very state the trap reads. When the keydown misses the trap entirely, native traversal walks focus out of the dialog and the failure reads as a broken focus trap rather than a lost keystroke. That is the CI-only flake behind [PR #430](https://github.com/mr-yum/growth-os/pull/430).

```ruby
# WRONG — moves the focus the trap is about to read, then may miss the listener
find("body").send_keys(:tab)
find("body").send_keys([ :shift, :tab ])

# CORRECT — dispatch from the focused element, as a real keypress does
press_tab
press_tab(shift: true)
```

**Where you dispatch differs from `press_escape`, and it is load-bearing.** Esc rides a `keydown.esc@window` action, so a window dispatch reaches it. The trap is a **`document` listener in the capture phase**, which an event dispatched *on* `window` never reaches — window is the root of the propagation path, not a descendant of document. `press_tab` therefore defaults to dispatching from `document.activeElement`, which captures down through document on its way. Read where the listener is bound before adding the next key helper; the answer is not the same twice running.

**A synthetic key event performs no native traversal**, so the trap's own `focus()` call is the only thing that can move focus. The assertions keep their bite — a trap that declines to act leaves focus where it was, which is never the edge element the caller asserts. Verified by disabling `trapKeydown` and watching the test fail.

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

**`wait_for_turbo_idle` is not a substitute.** It waits for `turbo-frame[busy]`, and a frame is busy only once its fetch has started. A `loading: "lazy"` frame revealed by a toggle (the assessment activity pane) starts its fetch when it scrolls into view, which a busy runner can delay past the idle check. The load then lands after the test has acted, and the controllers inside reconnect with fresh state: the feed's filter resets, a cleared focus comes back. Wait for `[complete]` instead. To reproduce a late start, hold the request in a `turbo:before-fetch-request` listener (`event.preventDefault()`, then `event.detail.resume()` on a timer); the frame stays neither busy nor complete for as long as you hold it. Slowing the server doesn't reproduce it: the frame goes busy at once, and the idle check waits.

## Measuring a Scroll: Wait for It to Stop

**Read a scroll position only once the page has stopped scrolling, and never
after a fixed `sleep`.** A smooth scroll takes as long as the browser needs,
and the assessment chip's scroll ends with a settle pass 600ms later. A chip
clicked before the matrix frame's own load lands also waits for that load
before scrolling at all. A slow worker can stretch either past any fixed sleep,
and the reading then describes a scroll that hasn't happened yet: the card
sits exactly where the test put it. That is how the chip-scroll tests failed
under a full parallel precommit and passed alone
([#501](https://github.com/mr-yum/growth-os/issues/501)).

- Wait for the eager frame (`turbo-frame#…[complete]`) and its controller
  (`wait_for_stimulus`) before arranging the page and clicking.
- Poll until the condition holds on two readings at the same `scrollY`. The
  assessment tests' `assert_card_settles` is the example.
- Reproduce a timing flake by slowing the server rather than the browser. 8x
  CPU throttling never failed these tests; a 1.5s delay prepended to the frame
  action failed both every time.

**Sideways overflow is a layout reading too: use `assert_no_sideways_overflow`.**
Reading `scrollWidth` forces a layout, but async work can still change the next
one: an observer, a frame load, a transition. The explorer's rename test once
read 375 against 360 on CI, a scrollbar its own failure screenshot no longer
showed. The helper polls until two reads in a row fit, so lasting overflow and
a layout that keeps flipping both still fail.

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

## Measuring Contrast in System Tests — `ContrastHelpers`

**Assert contrast as the browser paints it, not as the class list reads.**
`include ContrastHelpers` (`test/support/system/contrast_helpers.rb`) gives
`rendered_contrast(css)` — an element against every ancestor background,
ancestor `opacity` included — and `utility_contrast(utility, background)` for
a token on a flat surface. Tenant overrides and an emulated colour scheme
(`Emulation.setEmulatedMedia`, as the evidence report test does) all count.
Before you trust a new contrast test, revert the fix and watch it fail with
the number axe reported.

Three traps it already handles or that bit writing it:

- **A just-toggled control is mid-transition.** A pressed chip with
  `transition-colors` measured 3.8:1 when its settled colours are 17:1.
  `rendered_contrast` finishes the running animations on the element and its
  ancestors before it reads.
- **An interpolating heredoc eats a regex backslash.** Inside `<<~JS`, Ruby
  turns `\(` into `(`, so `/rgba?\([^)]*\)/` silently becomes a different
  regex and matches nothing. Write `\\(` in the Ruby source.
- **Keyboard focus without a keypress.** `send_keys(:tab)` is banned (see
  *Flake-Prone Click Guards*), and `press_tab` performs no native traversal.
  A script `element.focus()` on a page with no prior pointer input does match
  `:focus-visible` in Chrome, so focus-ring tests focus by script and assert
  `matches(":focus-visible")` before measuring the ring.

## Running One System-Test File — `bin/rails test <path>`

**`test:system` ignores a path argument and runs the whole system suite.**
`bin/rails test:system test/system/foo.rb` boots all ~520 system tests (about
11 minutes) and reports a pass, so nothing tells you the filter was dropped —
you just wait, and a failure from an unrelated file looks like yours. The
`TEST=` form is worse: `bin/rails test:system TEST=test/system/foo.rb` dies
with `Rails::TestUnit::InvalidTestError` and a "Did you mean?" listing the
path you already passed.

Give the path to `bin/rails test` instead — it excludes system tests by
default but runs them when the path names them, and it accepts several:

```bash
bin/rails test test/system/assessments_system_test.rb                 # one file
bin/rails test test/system/{assessments,manager_assessments}_system_test.rb
bin/rails test:system                                                 # deliberately all of them
```

## A `def` Inside a `context` Block Is Invisible to `should`

Shoulda's `should` blocks are `instance_exec`'d against the test instance, but
a `def` written inside a `context` block defines the method on the context
object instead. The failure is a bare `NameError: undefined local variable or
method 'my_helper'` at run time, which reads like a typo rather than a scoping
rule:

```ruby
# WRONG — the should block cannot see it
context "the score" do
  def render_with_diverging_self = render_hero(...)

  should "..." do
    render_with_diverging_self   # NameError
  end
end

# CORRECT — define it on the test class, use it from any context
def render_with_diverging_self = render_hero(...)

context "the score" do
  should "..." do
    render_with_diverging_self
  end
end
```

`setup` blocks are the exception — they run in the instance, so ivars set
there are visible as usual. Shared *behaviour* still belongs in a nested
context (see *Shared Setup Across Contexts*); this is only about helper
methods.

## Role Leak Tests — `create_out_of_scope_rating`

**Every query that reads `AssessmentLevelRating` gets an "ignores ratings outside the assessed role" test** (ADR-22, [assessments/role-lens.md → Role-scoped reads](assessments/role-lens.md)). The helper, in `test/support/out_of_scope_ratings.rb` and available in every test, builds the case the ordinal filters miss:

```ruby
rating = create_out_of_scope_rating(person_id: person.id, cycle: cycle, level_ordinal: 3)
# a capability bound only to another role, an expectation at L3, and a rating
# there — every side "consistent" and human-owned unless you override one
```

Rate at the person's **assessed** level: a rating at another level proves nothing, because most readers already filter by ordinal. Then prove the test bites: swap the reader's `.within(...)` for `.across_all_roles`, watch it fail, and put the guard back.

**Rating fixtures need a real role scope.** A reader scoped by `RoleScope` counts only cells where an **active** capability in the cycle's framework is **bound** to the person's role and carries an **expectation** at that level, with the role taken from the enrollment's `role_id` (or the assignment's before the snapshot existed). A factory rating on a random `capability_stable_id`, an enrollment with no `role_id`, or a capability with no binding silently reads as unrated. When an old test starts failing on a count of zero, check the fixture before the code.

### Two roles that share cells — `build_role_lens_framework`

For anything that reads *through* a lens, `test/support/role_lens_fixture.rb` builds Software Engineer (E1–E3) and Product Manager (PM1–PM3) sharing "Critical Thinking", with "Systems Design" E-only and "Roadmapping" PM-only; `enrol_in_role_lens_framework(person, fx, tenant:)` assigns E2 and enrols through the real command handlers **with the role/level snapshot** — cohort readers key on it, and an enrollment without one silently counts nothing. Prefer a real write through the lens (`Operations::Assessments::RateSelf` with `as_role_id`) over a hand-built row when the test is about what a lens write reaches (`test/queries/role_lens_leak_test.rb`).


## Rules

- Use `subject { }` to define the object under test
- Use `context` blocks to group related tests
- Use `should` matchers for validations, associations, callbacks
- Use FactoryBot (`build`, `create`, `build_stubbed`) — not fixtures for new tests
- Test happy paths, sad paths, and edge cases
