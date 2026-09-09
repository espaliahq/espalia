# frozen_string_literal: true

# Helpers for waiting on Stimulus controller readiness and performing
# CI-resilient toggle interactions in system tests.
#
# Stimulus controllers that extend BaseController set a `data-connected`
# attribute on their element when connected. These helpers wait for that
# signal before interacting with Stimulus-driven UI, preventing flaky
# tests on slow CI runners where action handlers aren't attached yet
# when Capybara clicks.
#
# == Toggle helpers
#
# On CI runners where Chrome's JS event loop is starved, a Selenium click
# can be silently lost. The toggle helpers click, verify the expected state
# change, retry once if the click was lost, and assert the final visible
# state. Each public helper encodes a specific controller's toggle contract.
#
# Usage:
#   wait_for_stimulus "framework-explorer"
#   open_dropdown
#   toggle_sidebar
#   toggle_role_pane
#   toggle_panel
#   expand_matrix_row("#capability-name-#{stable_id}")
module StimulusHelpers
  # == Recovery-script contracts (read before touching any evaluate_script here)
  #
  # Every JS recovery in this file depends on two things that are invisible at
  # the call site:
  #
  # 1. Capybara's +evaluate_script+ prepends `return ` to the script source,
  #    which is why each one is a single `(() => { ... })()` expression rather
  #    than a statement sequence.
  # 2. `arguments[0]` resolves ONLY because an arrow function inherits
  #    `arguments` from the WebDriver wrapper Selenium generates around the
  #    script. Rewriting any of these IIFEs as `function () { ... }` silently
  #    rebinds `arguments` to the empty inner list — every finder then matches
  #    against `undefined` and the recovery is disarmed suite-wide, with no
  #    error to say so.

  # Shared opening of every miss note — the greppable cue documented in
  # testing.md. Each phrase then carries its own cause hint.
  RECOVERY_NOTE_PREFIX = "note: JS recovery —"

  # Errors Selenium raises when a script runs against a document that is
  # being replaced. The recovery scripts run in exactly that window — right
  # after a click whose navigation may still be in flight — so these are a
  # normal condition here, not a test failure. +landed?+ already rescues the
  # same class for the same reason.
  RECOVERY_SCRIPT_ERRORS = [
    Selenium::WebDriver::Error::JavascriptError,
    Selenium::WebDriver::Error::StaleElementReferenceError,
    Selenium::WebDriver::Error::UnknownError
  ].freeze

  # What a recovery reports when it could not run at all.
  MID_NAVIGATION_PHRASE =
    "could not run — the document was being replaced mid-navigation, so no " \
    "recovery was attempted (not a locator problem)"

  # Locates a button the way +click_button_with_js_fallback+'s recovery does,
  # leaving it in `btn`. Shared by both recovery stages so a one-sided edit
  # can never make them resolve different buttons.
  BUTTON_FINDER_JS = <<~JS
    const text = arguments[0];
    const buttons = Array.from(document.querySelectorAll("button, input[type='submit']"));
    const btn = buttons.find(b => {
      const label = (b.textContent || b.value || "").trim();
      return label === text || label.includes(text);
    });
  JS

  # Waits until the named Stimulus controller has connected.
  #
  # @param controller_name [String] the Stimulus controller identifier
  #   (e.g. "framework-explorer", "dropdown", "matrix")
  # @param scope [String, nil] optional CSS selector to scope the search
  #   (e.g. "[data-framework-explorer-target='rolePaneToggle']")
  def wait_for_stimulus(controller_name, scope: nil)
    selector = "[data-controller~='#{controller_name}'][data-connected]"
    selector = "#{scope} #{selector}" if scope
    assert_selector selector, visible: :all
  end

  # Opens a dropdown menu.
  #
  # @param scope [String, nil] optional CSS selector to scope the toggle
  def open_dropdown(scope: nil)
    wait_for_stimulus "dropdown", scope: scope
    stimulus_toggle(
      "[data-action='dropdown#toggle']",
      # The menu TARGET, not [role='menu'] — non-menuitem panels (the
      # drill-in's level ⓘ) correctly carry role="dialog".
      visible_selector: "[data-dropdown-target='menu']",
      verify_selector: "[data-action='dropdown#toggle'][aria-expanded='true']",
      scope: scope
    )
  end

  # Opens the mobile sidebar drawer.
  #
  # @param scope [String, nil] optional CSS selector to scope the toggle
  def toggle_sidebar(scope: nil)
    # Sidebar doesn't extend BaseController. Wait for target registration
    # as a readiness signal.
    drawer_selector = "[data-sidebar-target='drawer']"
    drawer_selector = "#{scope} #{drawer_selector}" if scope
    assert_selector drawer_selector, visible: :all

    stimulus_toggle(
      "[data-action='sidebar#toggle']",
      visible_selector: "[data-sidebar-target='drawer']",
      scope: scope
    )
  end

  # Opens the framework explorer role pane.
  #
  # @param scope [String, nil] optional CSS selector to scope the toggle
  def toggle_role_pane(scope: nil)
    wait_for_stimulus "framework-explorer", scope: scope
    stimulus_toggle(
      "[data-action='framework-explorer#toggleRolePane']",
      visible_selector: "[data-framework-explorer-target='rolePane']",
      scope: scope
    )
  end

  # Opens the framework explorer context (right) pane.
  #
  # @param scope [String, nil] optional CSS selector to scope the toggle
  def toggle_context_pane(scope: nil)
    wait_for_stimulus "framework-explorer", scope: scope
    stimulus_toggle(
      "[data-action='framework-explorer#toggleContextPane']",
      visible_selector: "[data-framework-explorer-target='contextPane']",
      scope: scope
    )
  end

  # Opens a panel (e.g. scoring panel).
  #
  # @param scope [String, nil] optional CSS selector to scope the toggle
  def toggle_panel(scope: nil)
    # Panel doesn't extend BaseController. Wait for target registration
    # as a readiness signal.
    panel_selector = "[data-panel-target='panel']"
    panel_selector = "#{scope} #{panel_selector}" if scope
    assert_selector panel_selector, visible: :all

    stimulus_toggle(
      "[data-action='panel#toggle']",
      visible_selector: "[data-panel-target='panel']",
      scope: scope
    )
  end

  # Expands a matrix row by clicking the given capability selector.
  #
  # @param capability_selector [String] CSS selector for the capability
  #   element to click (e.g. "#capability-name-{stable_id}")
  # @param scope [String, nil] optional CSS selector to scope the toggle
  # The explorer fetches the expanded row's content on first expand (Hard-Won
  # Lesson 25), so by default this also waits for the loaded row — a
  # `querySelector` into the row straight after the click would otherwise race
  # the fetch. Pass `await_content: false` when the load itself is under test.
  def expand_matrix_row(capability_selector, scope: nil, await_content: true)
    wait_for_stimulus "matrix", scope: scope
    stimulus_toggle(
      capability_selector,
      visible_selector: "[data-matrix-target='expandedRow']",
      scope: scope
    )
    return unless await_content

    loaded = "[data-matrix-target='expandedRow']:not([data-loaded='false'])"
    assert_selector(scope ? "#{scope} #{loaded}" : loaded, visible: true)
  end

  # Opens the explorer's shared inline editor for one host (illustration /
  # capability / category / expectation / org-structure frame) by JS-dispatching
  # its hover-revealed pencil — the real `field-editor#open` path, which a
  # synthetic pointer click on an `opacity-0` button drops on starved CI — and
  # waits for the cloned form to appear.
  #
  # @param container [Capybara::Node::Element, String] the element (or CSS
  #   selector) carrying — or containing — the `data-editor-action` host
  # @return [Capybara::Node::Element] the editor form
  def start_inline_edit(container)
    element = container.is_a?(String) ? find(container) : container
    host = if element.matches_css?("[data-editor-action]")
      element
    else
      element.find("[data-editor-action]", visible: :all, match: :first)
    end
    # ONE controller drives every editor, on the explorer root — wait for it to
    # connect before dispatching, or the click has no handler.
    assert_selector "[data-controller~='field-editor'][data-connected]", visible: :all, match: :first
    page.execute_script(
      "arguments[0].querySelector(\"[data-action*='field-editor#open']\").click();", host
    )
    host.find("[data-editor-form]", visible: true)
  end

  # Sets the open editor's textarea via JS (Selenium drops characters on starved
  # CI) and submits with requestSubmit() — see testing.md, "Inline-Editor Form
  # Submits".
  #
  # @param form [Capybara::Node::Element] the form returned by +start_inline_edit+
  # @param with [String] the value to save
  def submit_inline_edit(form, with:)
    page.execute_script(<<~JS, form, with.to_s)
      const [f, value] = [arguments[0], arguments[1]]
      const input = f.querySelector("[data-editor-input]")
      input.value = value
      input.dispatchEvent(new Event("input", { bubbles: true }))
      input.dispatchEvent(new Event("change", { bubbles: true }))
      f.requestSubmit()
    JS
  end

  # Cancels the open editor via its Cancel button (JS-dispatched) and waits for
  # the host to be back in read mode — like every other toggle helper, this
  # asserts the resulting visible state, so a dropped cancel fails here instead
  # of surfacing later as a confusing assertion about whatever the still-open
  # editor covers.
  #
  # @param form [Capybara::Node::Element] the form returned by +start_inline_edit+
  # @return [Capybara::Node::Element] the host, back in display mode
  def cancel_inline_edit(form)
    host = form.ancestor("[data-editor-action]")
    page.execute_script(
      "arguments[0].querySelector(\"[data-action*='field-editor#cancel']\").click();", form
    )
    host.assert_no_selector("[data-editor-form]")
    host.assert_selector("[data-editor-display]", visible: true)
    host
  end

  # Performs a click via the given block and retries it once if the expected
  # text or selector does not appear within a short window. Use this for
  # Turbo Drive navigation clicks and Turbo Frame link clicks that may be
  # silently dropped when Chrome's event loop is starved on slow CI runners.
  #
  # Pass EXACTLY ONE success signal — see +assert_exactly_one_signal!+.
  #
  # @param expect_text [String, nil] text that should appear after the click
  # @param expect_selector [String, nil] CSS selector that should appear
  #   after the click (alternative to +expect_text+)
  # @yield the block performing the click (e.g. `click_on "Save"` inside a `within`)
  #
  # @example Click a Turbo Frame link in a panel and retry if dropped
  #   click_with_retry(expect_text: "Execution") do
  #     within("#scoring-panel") { click_on "Delivering" }
  #   end
  def click_with_retry(expect_text: nil, expect_selector: nil)
    guard_click_signal!(__method__, expect_text: expect_text, expect_selector: expect_selector)

    yield

    # Wait long enough for a slow CI Turbo Frame round-trip before deciding
    # the click was dropped. Too short (2s) and the retry fires mid-navigation,
    # potentially interfering with the in-flight fetch.
    landed =
      if expect_text
        page.has_text?(expect_text, wait: landed_wait)
      else
        page.has_css?(expect_selector, wait: landed_wait)
      end

    yield unless landed

    # The final wait also needs to be generous: when we retry a dropped click,
    # the fresh navigation + Turbo round-trip itself can exceed Capybara's
    # default on a starved CI runner. We've observed cases where even an 8s
    # wait misses on the first runner cycle of the day — bumping to match
    # Capybara's default_max_wait_time gives us full headroom.
    #
    # No misses to report: this helper retries the Capybara click rather than
    # running a JS recovery, so there is no finder that can come up empty.
    assert_after_recovery([], expect_text: expect_text, expect_selector: expect_selector)
  end

  # Clicks a link by locator, retrying with a JS-dispatched click if the
  # Capybara pointer click is dropped. Selenium's synthetic click is
  # vulnerable on starved CI runners; +click_with_retry+ retries the same
  # Capybara click which can be dropped a second time. JS dispatch is
  # synchronous and bypasses pointer hit-testing entirely, so the second
  # attempt is guaranteed to fire.
  #
  # Pass EXACTLY ONE success signal — see +assert_exactly_one_signal!+.
  #
  # @param locator [String] the link text/locator
  # @param expect_text [String, nil] text expected on destination
  # @param expect_selector [String, nil] selector expected on destination
  def click_link_with_js_fallback(locator, expect_text: nil, expect_selector: nil)
    guard_click_signal!(__method__, expect_text: expect_text, expect_selector: expect_selector)

    # An intercepted click (a sticky overlay — the comparison drawer, a
    # sticky header — sitting over the link at the current scroll) is the
    # same failure the JS dispatch below exists for; don't let it raise.
    begin
      click_link locator
      return if landed?(expect_text, expect_selector, wait: landed_wait)
    rescue Selenium::WebDriver::Error::ElementClickInterceptedError
      # fall through to the JS dispatch
    end

    # First click was dropped. Re-find the link and dispatch a synthetic
    # click via JS — bypasses Selenium pointer hit-testing. Reports whether
    # it found one, so a miss can explain a later failure (see
    # +assert_after_recovery+).
    #
    # The finder mirrors Capybara's own link resolution — id and title as
    # well as text. Matching text alone left the recovery permanently dead
    # for an id- or title-style locator, and the miss note then asserted the
    # opposite of the truth: it blamed a drifted locator when a dropped click
    # was exactly what had happened.
    clicked = evaluate_recovery_script(<<~JS, locator)
      (() => {
        const text = arguments[0];
        const links = Array.from(document.querySelectorAll("a"));
        const link = links.find(a =>
          a.id === text ||
          (a.getAttribute("title") || "") === text ||
          a.textContent.trim() === text ||
          a.textContent.includes(text)
        );
        if (!link) return false;
        link.click();
        return true;
      })()
    JS

    misses = single_stage_misses(clicked, "found no <a> matching #{locator.inspect}")

    assert_after_recovery(misses, expect_text: expect_text, expect_selector: expect_selector)
  end

  # Like +click_link_with_js_fallback+ but for elements addressed by a CSS
  # selector rather than visible text (e.g. the calibration drill-in's
  # person dots, `a[data-person-id=…]`). One Capybara click; if the
  # destination signal doesn't land, a synchronous JS `el.click()` bypasses
  # Selenium pointer hit-testing entirely.
  #
  # Pass EXACTLY ONE success signal — see +assert_exactly_one_signal!+.
  #
  # @param selector [String] CSS selector of the element to click
  # @param expect_text [String, nil] text expected after the click
  # @param expect_selector [String, nil] selector expected after the click
  def click_selector_with_js_fallback(selector, expect_text: nil, expect_selector: nil)
    guard_click_signal!(__method__, expect_text: expect_text, expect_selector: expect_selector)

    begin
      find(selector, match: :first).click
      return if landed?(expect_text, expect_selector, wait: landed_wait)
    rescue Selenium::WebDriver::Error::ElementClickInterceptedError
      # A sticky overlay (the comparison drawer) at the current scroll is
      # the same drop the JS dispatch below exists for.
    end

    clicked = dispatch_js_click(selector)
    misses = single_stage_misses(clicked, "matched no element for #{selector.inspect}")

    assert_after_recovery(misses, expect_text: expect_text, expect_selector: expect_selector)
  end

  # Like +click_link_with_js_fallback+ but for buttons (incl. form submits).
  #
  # Pass +expect_no_text+ when the click's success signal is content
  # *disappearing* (e.g. "Stop impersonating" removing the banner). An
  # appearance signal must be text that only exists AFTER the click — text
  # already on the page satisfies the landed-check instantly and the fallback
  # never arms, so a dropped click sails through to the caller's assertions.
  #
  # Pass EXACTLY ONE success signal — see +assert_exactly_one_signal!+.
  #
  # @param locator [String] button text/locator
  # @param expect_text [String, nil] text expected after the click
  # @param expect_selector [String, nil] selector expected after the click
  # @param expect_no_text [String, nil] text expected to DISAPPEAR after the click
  def click_button_with_js_fallback(locator, expect_text: nil, expect_selector: nil, expect_no_text: nil)
    guard_click_signal!(
      __method__,
      expect_text: expect_text, expect_selector: expect_selector, expect_no_text: expect_no_text
    )

    begin
      click_button locator
      return if landed?(expect_text, expect_selector, expect_no_text, wait: landed_wait)
    rescue Selenium::WebDriver::Error::ElementClickInterceptedError
      # Same interception-is-a-drop rule as the link/selector helpers.
    end

    # First click dropped — fall back to JS click, which fires synchronously
    # and bypasses Selenium pointer hit-testing. The two recovery stages are
    # tracked separately so a failure can name which one found nothing.
    clicked = evaluate_recovery_script(<<~JS, locator)
      (() => {
        #{BUTTON_FINDER_JS}
        if (!btn) return false;
        btn.click();
        return true;
      })()
    JS

    return if landed?(expect_text, expect_selector, expect_no_text, wait: landed_wait)

    # JS click also dropped (or the synthetic click event bypassed Turbo's
    # submit interceptor). Submit the button's form via requestSubmit() —
    # invokes Turbo's submit-listener synchronously, the most reliable path.
    # Distinguishes "no such button" from "button outside any form": the
    # latter is a markup change, not a locator drift.
    outcome = evaluate_recovery_script(<<~JS, locator)
      (() => {
        #{BUTTON_FINDER_JS}
        if (!btn) return "no-button";
        const form = btn.closest("form");
        if (!form) return "no-form";
        form.requestSubmit(btn);
        return "submitted";
      })()
    JS

    assert_after_recovery(
      button_misses(locator, clicked, outcome),
      expect_text: expect_text, expect_selector: expect_selector, expect_no_text: expect_no_text
    )
  end

  # Sets a field's value via a JS assignment + dispatched input/change events,
  # instead of Selenium's per-character +send_keys+.
  #
  # `fill_in` types one character at a time, and on a starved CI runner those
  # keystrokes drop. That is nastier than a dropped click: the field looks
  # filled, but a debounced typeahead runs against "Ra" instead of "Raj" and
  # the failure surfaces much later as "no matches" — nothing points back at
  # the typing. (This is how the calibration participant picker failed.)
  #
  # Use it wherever the exact value is assertion-critical: typeahead queries,
  # names asserted after save, anything a Stimulus controller reads. Fields
  # that are only submitted can stay on +fill_in+.
  #
  # Accepts a Capybara element, a CSS selector, or a field locator
  # (label / name / id).
  #
  # @param target [Capybara::Node::Element, String]
  # @param with [String] the value to set
  def js_fill_in(target, with:)
    el = target.is_a?(Capybara::Node::Element) ? target : find_fillable(target)

    # A CSS-selector target can resolve to ANY element; `.value =` on a div
    # is a silent no-op expando, and on a checkbox/radio it changes the
    # submitted value rather than toggling checked — either way the failure
    # surfaces assertions later, pointing anywhere but here.
    tag = el.tag_name
    type = tag == "input" ? el[:type].to_s : nil
    if !%w[input textarea select].include?(tag) ||
       %w[checkbox radio file submit reset button].include?(type)
      resolved = type ? "an <input type=#{type}>" : "a <#{tag}>"
      raise ArgumentError,
            "js_fill_in resolved #{target.inspect} to #{resolved} — not a text-fillable control"
    end

    page.execute_script(<<~JS, el, with)
      const el = arguments[0];
      el.value = arguments[1];
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
    JS
    el
  end

  # Resolves a field locator (label / name / id) or CSS selector to an element.
  #
  # Zero-wait probes run first: the element is almost always already on the
  # page (callers assert page state before filling), and probing +find_field+
  # at the default wait meant every CSS-selector target burned the full 10s
  # before the +find+ fallback ever ran — ~10s of dead wait per call, minutes
  # across the suite. Only when nothing matches instantly does it fall back to
  # the original waiting lookups (an element still being rendered).
  #
  # @param target [String] field locator or CSS selector
  # @return [Capybara::Node::Element]
  def find_fillable(target)
    find_field(target, match: :first, wait: 0)
  rescue Capybara::ElementNotFound
    begin
      find(target, match: :first, wait: 0)
    rescue Selenium::WebDriver::Error::InvalidSelectorError
      # A label-style locator ("Participants (raters)") is not valid CSS, so
      # it can only ever be a field locator — wait on that alone and let its
      # informative ElementNotFound propagate (re-running `find` would bury
      # the miss under a cryptic invalid-selector error).
      find_field(target, match: :first)
    rescue Capybara::ElementNotFound
      begin
        find_field(target, match: :first)
      rescue Capybara::ElementNotFound
        find(target, match: :first)
      end
    end
  end

  # The single entry point every guarded click helper calls first: exactly
  # one success signal, and that signal must be a real transition.
  #
  # One choke point rather than two calls per helper — the two checks share
  # their inputs, and the helper's name comes from +__method__+ so a rename
  # can't leave a hand-typed string blaming the wrong method.
  #
  # Exactly-one: the helpers pick their signal by strict precedence
  # (text > selector > no_text) in the landed-check AND in the final
  # assertion, so without this a call passing two signals would have all but
  # the first SILENTLY IGNORED — never armed, never asserted. An author
  # writing `expect_text: "Saved", expect_selector: "#draft-badge"` believing
  # both are checked would get exactly the disarmed-fallback bug this
  # machinery exists to catch, reintroduced through the ignored argument.
  # When a click genuinely needs two assertions, assert the second yourself
  # after the helper returns.
  #
  # @param helper [Symbol] the calling helper — pass +__method__+
  # @param signals [Hash{Symbol=>String,nil}] only the signal kwargs that
  #   helper accepts, in precedence order
  def guard_click_signal!(helper, **signals)
    assert_exactly_one_signal!(helper, **signals)
    assert_signal_is_a_transition!(
      signals[:expect_text], signals[:expect_selector], signals[:expect_no_text]
    )
  end

  # The exactly-one half of +guard_click_signal!+, split out so each check
  # stays independently readable and testable.
  #
  # @param helper [Symbol] the calling helper — pass +__method__+
  # @param signals [Hash{Symbol=>String,nil}] only the signal kwargs that
  #   helper accepts, in precedence order
  # @raise [ArgumentError] when zero, or more than one, signal is supplied
  def assert_exactly_one_signal!(helper, **signals)
    supplied = signals.compact.keys
    return if supplied.size == 1

    accepted = signals.keys.map { |key| "#{key}:" }.join(", ")
    given = supplied.empty? ? "none" : supplied.map { |key| "#{key}:" }.join(" + ")

    raise ArgumentError,
          "#{helper}: pass exactly one of #{accepted} (given: #{given}). " \
          "The helper checks a single signal by precedence, so a second one " \
          "would be silently ignored — never armed, never asserted."
  end

  # Refuses a success signal that is ALREADY true before the click.
  #
  # A guarded click helper decides "the click was dropped" by checking whether
  # its signal appeared. If the signal was on the page all along, that check
  # succeeds instantly, the recovery (a retry, or the JS dispatch) never arms,
  # and a dropped click sails through to the caller's real assertions — which
  # is how a guarded test can still fail on CI (`expect_text: "Brand colors"`
  # on a dashboard whose tile already read "Brand colors and typography for
  # this tenant."). Same shape as `expect_selector: "body"`.
  #
  # Fails loudly at authoring time instead: pick a signal that only exists on
  # the far side of the click. See testing.md, "An Assertion a Dropped Click
  # Would Also Satisfy Is Not a Test".
  def assert_signal_is_a_transition!(expect_text, expect_selector, expect_no_text = nil)
    if expect_text && page.has_text?(expect_text, wait: 0)
      raise ArgumentError,
            "expect_text #{expect_text.inspect} is already on the page before the click, " \
            "so the dropped-click detection can never arm. Pick text that only the " \
            "destination renders."
    elsif expect_selector && page.has_css?(expect_selector, wait: 0)
      raise ArgumentError,
            "expect_selector #{expect_selector.inspect} already matches before the click, " \
            "so the dropped-click detection can never arm. Pick a selector only the " \
            "destination renders."
    elsif expect_no_text && page.has_no_text?(expect_no_text, wait: 0)
      raise ArgumentError,
            "expect_no_text #{expect_no_text.inspect} is already absent before the click, " \
            "so the dropped-click detection can never arm. Pick text that is visible " \
            "until the click lands."
    end
  end

  def landed?(expect_text, expect_selector, expect_no_text = nil, wait:)
    if expect_text
      page.has_text?(expect_text, wait: wait)
    elsif expect_selector
      page.has_css?(expect_selector, wait: wait)
    else
      page.has_no_text?(expect_no_text, wait: wait)
    end
  rescue Selenium::WebDriver::Error::StaleElementReferenceError, Selenium::WebDriver::Error::UnknownError
    # A Turbo render replacing the document mid-probe can surface as a raw
    # inspector error ("Node with given id does not belong to the document").
    # That's "not landed yet", not a test failure — report false so the
    # caller's JS fallback / final assertion takes over.
    false
  end

  # Dispatches an Escape keydown on the window, rather than
  # +find("body").send_keys(:escape)+.
  #
  # Stimulus binds Esc as +keydown.esc@window+, but Selenium's key dispatch
  # needs a focused, interactable target — and once a modal opens, focus has
  # moved into the dialog (the APG focus management), so keys aimed at +body+
  # can be swallowed and the handler never runs. The failure is silent and
  # reads as "the modal didn't close" or "confirm was never called", which is
  # indistinguishable from a real bug. This is the same remedy the suite
  # already uses for click-outside listeners: construct the event and dispatch
  # it where the listener actually is.
  #
  # A +scope+ that matches nothing is fatal, never a fallback to +window+.
  # Silently degrading defeated the point of the scope: `press_escape(scope:
  # "#evm-content")` means "Esc originates INSIDE the dialog", but a window
  # dispatch still closes the modal (the listener is `keydown.esc@window`),
  # so the test passed while testing nothing about in-dialog dispatch — the
  # miss invisible whether the modal failed to open or the id was renamed.
  # Same fail-loud principle as +js_fill_in+'s non-fillable guard.
  #
  # The scope is resolved ONCE, by Capybara, and the element itself is passed
  # to the script — as +js_fill_in+ does. Resolving it twice (assert_selector
  # then a document-global +querySelector+) used two different lookups: inside
  # a +within+ block Capybara scopes to the current node while querySelector
  # does not, so the helper could assert one element and dispatch on another
  # (or none). +find+'s ElementNotFound is the loud failure.
  #
  # Resolution is VISIBLE-ONLY (Capybara's default), deliberately. Several
  # modals are embedded in the initial render and merely hidden until opened,
  # so +visible: :all+ would resolve the hidden panel after a dropped
  # open-click: Esc dispatches from a hidden node, bubbles to window, and the
  # caller's `assert_no_selector …, visible: true` passes vacuously against a
  # modal that never opened. Visible-only makes that fail loudly too.
  #
  # So pass +scope+ only when the element is expected to be present AND
  # visible at dispatch time. For a close-path sequence where it may already
  # be gone (a second Esc, say), use bare +press_escape+ — the listener is on
  # the window regardless.
  #
  # @param scope [String, nil] CSS selector to dispatch from (bubbles to
  #   window); defaults to the window itself
  def press_escape(scope: nil)
    target = scope ? find(scope) : nil

    if target
      page.execute_script(<<~JS, target)
        arguments[0].dispatchEvent(
          new KeyboardEvent("keydown", { key: "Escape", code: "Escape", keyCode: 27, bubbles: true })
        );
      JS
    else
      page.execute_script(<<~JS)
        window.dispatchEvent(
          new KeyboardEvent("keydown", { key: "Escape", code: "Escape", keyCode: 27, bubbles: true })
        );
      JS
    end
  end

  # Stubs +window.confirm+ to always return true, then runs the block.
  # Use for clicks that submit forms with +data-turbo-confirm+ when the
  # action under test is the form submission, not the dialog itself.
  #
  # On slow CI runners, Capybara's +accept_confirm+ has a race window
  # between the click and the dialog appearing — when the JS event loop
  # is starved, the click can fire before Capybara's modal handler is
  # registered, so the dialog appears, fires confirm() instantly with no
  # handler, and is gone before Capybara polls. Stubbing +window.confirm+
  # eliminates that race: Turbo's submit-listener calls confirm() and our
  # stub returns true with no dialog ever showing.
  #
  # We deliberately DO NOT restore +window.confirm+ afterwards. For a
  # +data-turbo-method+ LINK (vs. a form-submit button), Turbo invokes
  # confirm() asynchronously — after the synchronous +.click+ returns — so an
  # +ensure+ that restored the native confirm raced the click and let a real
  # dialog open on starved CI (+UnexpectedAlertOpenError+, which then poisons
  # every later command). Leaving the stub in place is safe: it only suppresses
  # +data-turbo-confirm+ dialogs, and a full-page navigation loads a fresh
  # document that resets +window.confirm+ to native on its own.
  #
  # @yield the block performing the click that triggers the confirm dialog
  def auto_confirm
    page.execute_script("window.confirm = () => true;")
    yield
  end

  # Wraps Capybara's +accept_confirm+ to retry up to two more times if the
  # dialog never appears — on slow CI runners, the click that should
  # trigger Turbo's +data-turbo-confirm+ dialog is occasionally dropped.
  # Without retry, +Capybara::ModalNotFound+ raises on the first attempt.
  #
  # Forwards any positional matcher (text or regex) and the +wait+ kwarg
  # straight through to +accept_confirm+, so it's a drop-in replacement.
  #
  # @yield the block performing the click that triggers the confirm dialog
  def accept_confirm_with_retry(*args, wait: 5, &block)
    # Turbo intercepts form submissions with +data-turbo-confirm+ at submit
    # time. If +window.Turbo+ isn't yet defined when the click fires, the
    # form submits directly and no dialog appears. Wait for Turbo to load
    # before the first attempt so the dialog has the best chance of showing.
    wait_for_turbo_ready

    attempts = 0
    begin
      attempts += 1
      # This is the canonical accept_confirm wrapper for tests that DO assert
      # on dialog text — the FlakeProneClick cop's escape hatch lives here.
      accept_confirm(*args, wait: wait, &block) # rubocop:disable SystemTests/FlakeProneClick
    rescue Capybara::ModalNotFound
      raise if attempts >= 3

      # Brief pause lets any in-flight Turbo + Stimulus boot finish before
      # the next click — clicks fired during the boot are the typical cause
      # of dropped Turbo-confirm dialogs.
      sleep 0.5
      retry
    end
  end

  # Polls the browser until +window.Turbo+ is defined. Turbo's submission
  # interception relies on this global being installed — clicks fired
  # before it loads will bypass +data-turbo-confirm+ entirely.
  def wait_for_turbo_ready(wait: Capybara.default_max_wait_time)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
    loop do
      return if page.evaluate_script("typeof Turbo !== 'undefined'")
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.1
    end
  end

  # Clicks a rating frequency button and retries once if the expected
  # ring-1 indicator never appears. Wraps the recurring pattern in
  # rating-cell tests where a Capybara pointer click can be silently
  # dropped on slow CI runners. Re-clicking is safe because the cell is
  # still in its un-rated state when the first click was lost.
  #
  # @param cell_selector [String] e.g. "#rating-{stable}-{level}"
  # @param frequency [String] button text — "Some" / "Most" / "Consistently"
  # Toggles the assessment activity pane by directly invoking the
  # Stimulus controller's #toggle method. JS pointer clicks on the
  # toggle button have been observed dropped on parallel CI runners
  # when Chrome's event loop is starved, so we bypass the event chain
  # entirely and call the controller method.
  def toggle_activity_pane
    page.execute_script(<<~JS)
      const wrapper = document.querySelector("[data-controller~='activity-pane']");
      const ctrl = window.Stimulus.getControllerForElementAndIdentifier(wrapper, "activity-pane");
      ctrl.toggle();
    JS
  end

  # Picks a frequency on the inline pill (open popover → click option).
  # Substring match — callers pass "Some" / "Most" / "Consistently" /
  # "Never" and we find the popover option whose phrase contains it.
  # Falls back to a synchronous form.requestSubmit if the Capybara
  # pointer click is silently dropped on a starved CI runner.
  #
  # @param cell_selector [String] e.g. "#rating-{stable}-{level}"
  # @param frequency [String] short phrase to match
  def click_rating_frequency(cell_selector, frequency)
    open_pill_popover(cell_selector)

    # The comment below has always named this failure mode; now the helper
    # reports it rather than leaving the reader to infer it.
    outcome = evaluate_recovery_script(<<~JS, cell_selector, frequency)
      (() => {
        const wrapper = document.querySelector(arguments[0]);
        if (!wrapper) return "no-wrapper";
        const items = Array.from(wrapper.querySelectorAll('[role="menuitem"]'));
        const item = items.find(b => b.textContent.trim().includes(arguments[1]));
        if (!item) return "no-item";
        const form = item.closest("form");
        if (!form) return "no-form";
        form.requestSubmit(item);
        return "submitted";
      })()
    JS

    # Final assertion ensures we surface a real failure if the JS fallback
    # also silently no-ops (selector wrong, item missing, etc) — without
    # this the helper returns successfully and the caller asserts against
    # stale UI state. The pill's trigger label updates with the new
    # phrase on success — we assert on the trigger button rather than
    # any specific ring/selected class so the assertion survives styling
    # changes.
    assert_after_recovery(rating_misses(cell_selector, frequency, outcome)) do
      assert_selector "#{cell_selector} button[aria-haspopup='menu']", text: frequency
    end
  end

  # Opens the pill popover. Stimulus dropdown click handling is robust
  # but on starved CI runners a pointer click can be lost; fall back to
  # a synchronous `.click()` via execute_script the same way other
  # toggle helpers in this file do.
  def open_pill_popover(cell_selector)
    trigger_selector = "#{cell_selector} button[aria-haspopup='menu']"
    return unless page.has_css?(trigger_selector, wait: 4)

    # Already open? Skip.
    return if page.has_css?("#{cell_selector} [role='menu']:not(.hidden)")

    find(trigger_selector).click
    return if page.has_css?("#{cell_selector} [role='menu']:not(.hidden)", wait: 2)

    clicked = dispatch_js_click(trigger_selector)
    misses = single_stage_misses(clicked, "matched no pill trigger for #{trigger_selector.inspect}")

    assert_after_recovery(misses) do
      assert_selector "#{cell_selector} [role='menu']:not(.hidden)", wait: 4
    end
  end

  # Waits until Turbo Drive / Turbo Frame are idle — no busy frames, no
  # in-flight navigation. Use after a click that triggers Turbo navigation
  # and before reading state that depends on the destination DOM having
  # committed.
  #
  # @param wait [Integer] seconds to wait for idle (default Capybara's max)
  def wait_for_turbo_idle(wait: Capybara.default_max_wait_time)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait

    loop do
      idle = page.evaluate_script(<<~JS)
        (() => {
          if (document.querySelector('turbo-frame[busy]')) return false;
          if (document.querySelector('html[aria-busy="true"]')) return false;
          return true;
        })()
      JS
      return if idle

      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.1
    end
  end

  private

  # Runs a helper's final assertion, enriching the failure when one of its
  # JS recovery steps found no target.
  #
  # RECORD-THEN-ENRICH, deliberately not flunk-on-miss. A recovery step that
  # finds nothing is ambiguous: either the locator drifted (the bug we want
  # named), or the first Capybara click WAS honoured with a round-trip slower
  # than the landed-check window, so by the time the fallback ran the element
  # was legitimately gone because navigation landed. Flunking would trade one
  # misattributed failure for another — the same late-landing race the sign-in
  # helper handles with +left_sign_in_page?+.
  #
  # So the assertion keeps its full wait and a slow-but-successful click still
  # passes untouched; the miss is reported only when the assertion actually
  # fails, where a drifted locator is the likeliest explanation and the note
  # saves a debugging session spent on starved-runner theories.
  #
  # Owns the by-precedence final assertion as well, so the four helpers each
  # hand over their signals in one line instead of repeating the ladder.
  # A block wins over the signals, for callers whose final assertion is not a
  # text/selector wait (+stimulus_toggle+, +sign_in_as+).
  #
  # @param misses [Array<String>] one phrase per recovery step that found
  #   nothing; empty when every step acted
  # @param expect_text [String, nil] text the click should produce
  # @param expect_selector [String, nil] selector the click should produce
  # @param expect_no_text [String, nil] text the click should remove
  # @yield an assertion to run instead of the signal ladder
  # @raise [Minitest::Assertion] the original failure, with the notes appended
  def assert_after_recovery(misses, expect_text: nil, expect_selector: nil, expect_no_text: nil)
    if block_given?
      yield
    elsif expect_text
      assert_text expect_text, wait: Capybara.default_max_wait_time
    elsif expect_selector
      assert_selector expect_selector, wait: Capybara.default_max_wait_time
    else
      assert_no_text expect_no_text, wait: Capybara.default_max_wait_time
    end
  rescue Minitest::Assertion => e
    raise if misses.empty?

    raise e.class, "#{e.message}\n\n#{misses.join("\n")}", e.backtrace
  end

  # A miss phrase, carrying the prefix every note shares so a reader (or a
  # log grep) can spot one without knowing which helper produced it.
  #
  # @param text [String] the phrase, including its own cause hint
  # @return [String]
  def recovery_note(text)
    "#{RECOVERY_NOTE_PREFIX} #{text}"
  end

  # How long a guarded click waits before deciding it was dropped.
  #
  # Long enough for a slow CI Turbo Frame round-trip: too short and the
  # recovery fires mid-navigation, potentially interfering with the in-flight
  # fetch. Overridable so a test of the helpers' own wiring — where the
  # timeout is dead waiting, not part of the subject — can shrink it.
  #
  # @return [Integer, Float] seconds
  def landed_wait
    8
  end

  # Runs a recovery script, tolerating the document being swapped under it.
  #
  # A hard error here would fail a test the design promises can still pass:
  # the whole point of the record-then-enrich shape is that a slow first
  # click may land late, and that landing is precisely what tears the
  # document down while the script is running.
  #
  # @return [Object, :unavailable] the script's value, or +:unavailable+
  def evaluate_recovery_script(script, *args)
    page.evaluate_script(script, *args)
  rescue *RECOVERY_SCRIPT_ERRORS
    :unavailable
  end

  # Miss list for a recovery with a single find-and-act stage.
  #
  # @param acted [Boolean, :unavailable] whether the stage found its target
  #   and acted, or +:unavailable+ if the script could not run
  # @param missed_phrase [String] what to say when it did not
  # @return [Array<String>]
  def single_stage_misses(acted, missed_phrase)
    return [ recovery_note(MID_NAVIGATION_PHRASE) ] if acted == :unavailable

    acted ? [] : [ recovery_note(missed_phrase) ]
  end

  # Miss list for +click_rating_frequency+'s popover submit.
  #
  # @param cell_selector [String] the rating cell
  # @param frequency [String] the phrase the menu item should contain
  # @param outcome [String, :unavailable] the script's result
  # @return [Array<String>]
  def rating_misses(cell_selector, frequency, outcome)
    case outcome
    when "submitted" then []
    when :unavailable then [ recovery_note(MID_NAVIGATION_PHRASE) ]
    when "no-wrapper"
      [ recovery_note("the rating cell #{cell_selector.inspect} was not on the page") ]
    when "no-item"
      [ recovery_note("the popover under #{cell_selector.inspect} had no menu item containing " \
                      "#{frequency.inspect} — the popover may not have opened, or the phrase changed") ]
    else
      [ recovery_note("the #{frequency.inspect} menu item under #{cell_selector.inspect} sits " \
                      "outside any <form>, so it could not be submitted") ]
    end
  end

  # Miss list for +click_button_with_js_fallback+'s two stages.
  #
  # A note is owed only when NO stage acted. A stage that missed while the
  # other worked is not a problem to report: "no-form" is EXPECTED for a
  # plain Stimulus button whose click stage already fired, and a stage-1 miss
  # is moot once requestSubmit has submitted the form.
  #
  # @param locator [String] the button locator both stages used
  # @param clicked [Boolean] whether the JS click stage found a button
  # @param outcome [String] the requestSubmit stage's result
  # @return [Array<String>]
  def button_misses(locator, clicked, outcome)
    return [ recovery_note(MID_NAVIGATION_PHRASE) ] if [ clicked, outcome ].include?(:unavailable)
    return [] if clicked

    case outcome
    when "submitted"
      # Not drift: the button existed by the time the second stage looked.
      [ recovery_note("the JS click stage found no button matching #{locator.inspect}, but the " \
                      "requestSubmit stage later found and submitted it — likely rendered late") ]
    when "no-form"
      [ recovery_note("neither stage acted: the JS click stage found no button matching " \
                      "#{locator.inspect}, and the requestSubmit stage found one outside any <form>") ]
    else
      [ recovery_note("neither stage found a button matching #{locator.inspect} — the locator " \
                      "has likely drifted") ]
    end
  end

  # Clicks a toggle element via JS-dispatch and asserts the visible state.
  #
  # Capybara's default click simulates a real user pointer click, which on
  # slow CI runners has been observed to be silently dropped when Chrome's
  # JS event loop is starved, or when the target is momentarily obscured by
  # a sticky element, scroll position, or mid-flight layout.
  #
  # JS-dispatched click is synchronous (the Stimulus action handler runs
  # inline before +execute_script+ returns) and bypasses pointer
  # hit-testing entirely. In practice we have still seen rare cases on
  # 2-core CI runners where the dispatch returns before the handler has
  # finished its DOM mutations, or where the controller hadn't yet attached
  # delegated listeners despite +data-connected+ being set. To stay
  # deterministic without ping-pong, we re-dispatch the click only if the
  # toggle is still in its un-toggled state — re-clicking a toggle that has
  # already moved to the "visible" state would undo the first click, which
  # is exactly the bug we want to avoid.
  #
  # @param toggle_selector [String] CSS selector for the element to click
  # @param visible_selector [String] CSS selector that should become
  #   visible after the toggle (used for the final assertion)
  # @param verify_selector [String, nil] fast synchronous check selector
  #   (e.g. aria-expanded attribute). Checked with `visible: :all` since
  #   the attribute may be on a non-visible element. When provided, asserted
  #   before +visible_selector+ so animated transitions don't mask a
  #   synchronously-applied state change.
  # @param scope [String, nil] optional CSS scope prefix
  def stimulus_toggle(toggle_selector, visible_selector:, verify_selector: nil, scope: nil)
    toggle_selector = "#{scope} #{toggle_selector}" if scope
    scoped_visible = scope ? "#{scope} #{visible_selector}" : visible_selector
    scoped_verify = verify_selector && (scope ? "#{scope} #{verify_selector}" : verify_selector)

    # Wait for any in-flight Turbo Frame fetches to land before clicking.
    # Without this, a frame replacement after our click can detach the
    # element we just toggled, so the visible-state assertion races against
    # a fresh hidden DOM that the new frame just installed.
    wait_for_turbo_idle(wait: 5)

    # Idempotent: if the target is already visible (e.g. the framework-explorer
    # context pane is open by default in edit mode), the caller asked for "make
    # it visible" and it already is — no click needed.
    return if page.has_css?(scoped_visible, visible: true, wait: 0)

    # Surface genuine missing-target bugs. +assert_selector+ allows multiple
    # matches (unlike +find+), so callers that pass non-unique selectors like
    # `tr[data-capability-id]` still work — +querySelector+ below picks the
    # first one, which is intentional.
    assert_selector toggle_selector

    first_dispatch = dispatch_js_click(toggle_selector)

    # Wait for any Turbo Frame fetch the click might have triggered to
    # settle before the visibility check — otherwise a mid-flight frame
    # replacement can detach the element we just toggled.
    wait_for_turbo_idle(wait: 3)

    # Short window for the synchronous handler to flip the visible state.
    # If it lands, we're done after the standard verify+visible asserts.
    if page.has_css?(scoped_visible, visible: true, wait: 3)
      # Enriched too: the first dispatch's miss is already known here, and
      # these asserts can still fail (a verify attribute that never flipped).
      assert_after_recovery(dispatch_misses(toggle_selector, first_dispatch, :skipped)) do
        assert_selector scoped_verify, visible: :all, wait: 5 if scoped_verify
        assert_selector scoped_visible, visible: true
      end
      return
    end

    # First click was dropped or the controller hadn't fully wired its
    # action when we dispatched. Re-dispatch only because the toggle is
    # still in its un-toggled state — re-clicking a toggle that has already
    # moved to "visible" would undo the first click.
    second_dispatch = dispatch_js_click(toggle_selector)
    wait_for_turbo_idle(wait: 3)

    # A dispatch that matched nothing is worth naming: the assert_selector
    # above proved the toggle existed, so a miss here means it was detached
    # in between — the two wait_for_turbo_idle windows are exactly where a
    # Turbo Frame replacement would have done it. Without the note, a frame
    # that re-renders the toggle looks identical to a dropped click.
    misses = dispatch_misses(toggle_selector, first_dispatch, second_dispatch)

    assert_after_recovery(misses) do
      assert_selector scoped_verify, visible: :all, wait: 5 if scoped_verify
      assert_selector scoped_visible, visible: true
    end
  end

  # Describes which of +stimulus_toggle+'s two JS dispatches found nothing.
  #
  # @param selector [String] the toggle selector both dispatches used
  # @param first [Boolean] whether the first dispatch found an element
  # @param second [Boolean] whether the re-dispatch found one
  # @return [Array<String>] zero or one phrase for +assert_after_recovery+
  # Each branch carries the conclusion that is actually true of it: a
  # dispatch that missed while the other found the element points at a frame
  # RE-RENDER (the node was replaced, not removed), where a miss with no
  # successful sibling points at detachment.
  #
  # @param selector [String] the toggle selector the dispatches used
  # @param first [Boolean] whether the first dispatch found an element
  # @param second [Boolean, :skipped] the re-dispatch's result, or +:skipped+
  #   when the toggle went visible and no re-dispatch was needed
  # @return [Array<String>]
  def dispatch_misses(selector, first, second)
    return [ recovery_note(MID_NAVIGATION_PHRASE) ] if [ first, second ].include?(:unavailable)

    detached = "it WAS present when asserted, so a Turbo Frame replacement likely detached it"

    return first ? [] : [ recovery_note(only_dispatch_missed(selector, detached)) ] if second == :skipped
    return [] if first && second

    if !first && second
      return [ recovery_note("the first JS dispatch matched nothing for #{selector.inspect}, but " \
                             "the re-dispatch found it — a frame re-render, not a missing element") ]
    end

    missed = first ? "the re-dispatch" : "both JS dispatches"
    [ recovery_note("#{missed} matched nothing for #{selector.inspect} — #{detached} in between") ]
  end

  def only_dispatch_missed(selector, detached)
    "the JS dispatch matched nothing for #{selector.inspect} — #{detached} first"
  end

  # Dispatches a synchronous JS click on the first match.
  #
  # @param selector [String] CSS selector of the element to click
  # @return [Boolean, :unavailable] whether an element was found and clicked,
  #   or +:unavailable+ if the document was being replaced
  def dispatch_js_click(selector)
    evaluate_recovery_script(<<~JS, selector)
      (() => {
        const el = document.querySelector(arguments[0]);
        if (!el) return false;
        el.click();
        return true;
      })()
    JS
  end
end
