# frozen_string_literal: true

require "application_system_test_case"

# The suggestion discussion thread, on both surfaces:
# - the context pane's suggestion card (focus=suggestion) — opened from a
#   feed entry's discussion affordance; post + reply with one-indent display
# - the suggestion detail page's Discussion card
#
# Desktop covers the pane (a desktop-first surface); the detail page is
# checked at both viewports (it is a plain full-width page).
class Frameworks::SuggestionThreadSystemTest < ApplicationSystemTestCase
  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)

    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @person = FactoryBot.create(:person, tenant: @tenant, email: @user.email, name: "Olive Owner")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, role: :admin, person: @person)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_capability_category(@framework_id, @cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Strategic Thinking")
      handler.publish_version(@framework_id, "seed")
      handler.add_collaborator(@framework_id, @person.id.to_s, "owner", added_by: @person.id.to_s)

      @suggestion_id = SecureRandom.uuid_v7
      handler.suggest_edit(@framework_id, @suggestion_id, "capability", @cap_id,
                           "description", "Weighs long-term impact", @person.id.to_s,
                           mode: :suggesting)
    end

    sign_in_as(@user)
  end

  # Sets an assertion-critical textarea value via JS (Selenium send_keys can
  # drop characters on starved CI) and submits its form via requestSubmit —
  # the dropped-click class testing.md's inline-editor rule exists for.
  def compose_and_submit(textarea, text)
    page.execute_script(<<~JS, textarea, text)
      const [el, value] = [arguments[0], arguments[1]]
      el.value = value
      el.dispatchEvent(new Event("input", { bubbles: true }))
      el.dispatchEvent(new Event("change", { bubbles: true }))
      el.closest("form").requestSubmit()
    JS
  end

  # Posting broadcasts a signal that reloads the pane 300ms later and renders
  # the new comment again, so a menu opened or a reply box revealed before then
  # is wiped. Wait until no reload is pending or running and the comment has
  # gone unreplaced for a second.
  def wait_for_thread_to_settle
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    loop do
      settled_for = page.evaluate_script(<<~JS)
        (() => {
          const comment = document.querySelector("li[id^='comment-']")
          const pane = document.querySelector("[data-controller~='context-pane']")
          const reloading = window.Stimulus.getControllerForElementAndIdentifier(pane, "context-pane")?._syncReloadTimer ||
            pane.querySelector("turbo-frame[busy]")
          if (!comment) return 0
          if (reloading) { delete comment.dataset.settledSince; return 0 }
          comment.dataset.settledSince ||= String(Date.now())
          return Date.now() - Number(comment.dataset.settledSince)
        })()
      JS
      return if settled_for >= 1000
      flunk "the suggestion thread never settled" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.1
    end
  end

  def open_suggestion_card
    visit edit_framework_path(@framework_id)
    assert_text "Edit mode"
    # The pane is open by default in edit mode; the pending suggestion's
    # entry carries the discussion affordance.
    assert_selector "turbo-frame#suggestion-panel [data-suggestion-id='#{@suggestion_id}']"
    page.execute_script(<<~JS)
      document.querySelector("[data-suggestion-id='#{@suggestion_id}']").click()
    JS
    assert_text "Back to activity"
    assert_text "Weighs long-term impact"
  end

  # The permalink is how a question reaches the person who should answer it —
  # there are no notifications for discussions yet. So the link the card hands
  # you has to survive a cold visit, not just look right.
  should "reopen the discussion for someone arriving cold on the copied link" do
    open_suggestion_card

    permalink = find("[data-clipboard-target='source']", visible: :all).text.strip
    assert_includes permalink, "focus=suggestion"

    # Leave the explorer entirely, then arrive on the link as a recipient would.
    visit frameworks_path
    assert_no_text "Back to activity"

    visit permalink
    assert_text "Back to activity"
    assert_text "Weighs long-term impact"
  end

  # The clipboard controller's default feedback rewrites the button's
  # textContent — which would erase the inline SVG on the first copy. The icon
  # form swaps two glyphs instead.
  should "flash the copied glyph without destroying the link icon" do
    open_suggestion_card
    stub_clipboard_write

    assert_selector "[data-clipboard-target='idle']", visible: true
    assert_no_selector "[data-clipboard-target='copied']", visible: true

    click_with_retry(expect_selector: "[data-clipboard-target='copied']") do
      click_button "Copy a link to this discussion"
    end
    assert_no_selector "[data-clipboard-target='idle']", visible: true

    # Restores after the flash — with the link icon still present, not wiped.
    assert_selector "[data-clipboard-target='idle']", visible: true
    assert_no_selector "[data-clipboard-target='copied']", visible: true
  end

  # Comment sits 4px under the discussion box, so its hit area took clicks on
  # the box's bottom edge and posted.
  should "give the discussion box's edge to the discussion box" do
    open_suggestion_card
    assert_selector "textarea[name='comment[body]']", visible: true

    assert_no_stolen_taps
  end

  should "post and reply from the pane's suggestion card with one-indent display" do
    open_suggestion_card

    # URL carries the focus so the card is shareable.
    assert_includes current_url, "focus=suggestion"
    assert_includes current_url, "suggestion_id=#{@suggestion_id}"

    composer = find("textarea[name='comment[body]']", match: :first)
    compose_and_submit(composer, "Is 'long-term' the right frame?")
    assert_text "Is 'long-term' the right frame?"

    # Reply via the comment kebab — one level of indent on the reply card.
    # The Reply item is a Stimulus-action control, so dispatch the click via
    # JS (synthetic pointer clicks drop silently on starved CI).
    # Resolve AND click inside one script: the comment lives in a
    # Turbo-Stream-replaced thread frame, so a handle cached by `find` can go
    # stale before `execute_script` uses it (testing.md, "Avoiding Stale
    # Element References with Turbo Streams"). The revealed reply box below is
    # the success signal, so a miss here still fails loudly.
    wait_for_thread_to_settle
    open_dropdown(scope: "li[id^='comment-']")
    page.execute_script(<<~JS)
      const item = Array.from(
        document.querySelectorAll("li[id^='comment-'] [role='menu'] button")
      ).find((b) => b.textContent.trim() === "Reply");
      item?.click();
    JS
    # The reply form's visibility is the click's success signal (a
    # placeholder isn't page text, so assert on the revealed control).
    reply_box = find("textarea[placeholder='Reply…']", visible: true)
    compose_and_submit(reply_box, "I think it is")
    assert_text "I think it is"
    assert_selector "li.pl-5", text: /I think it is/

    # Back to the feed — the entry now advertises the discussion.
    click_link_with_js_fallback("← Back to activity", expect_text: "2 · I think it is")
    assert_text "2 · I think it is"
  end

  should "open a comment's menu from the keyboard and close it with Esc" do
    open_suggestion_card
    compose_and_submit(find("textarea[name='comment[body]']", match: :first), "Keyboard check")
    assert_text "Keyboard check"

    trigger = "li[id^='comment-'] button[aria-label='Comment actions']"
    wait_for_thread_to_settle
    wait_for_stimulus "dropdown", scope: "li[id^='comment-']"
    page.execute_script("document.querySelector(arguments[0]).focus()", trigger)
    find(trigger).send_keys(:enter)
    assert_selector "#{trigger}[aria-expanded='true']"
    assert_selector "li[id^='comment-'] [role='menuitem']", text: "Reply", visible: true

    # Read in the same tick as the key: a late re-render of the comment resets the attribute.
    expanded = page.evaluate_script(<<~JS, find(trigger))
      (trigger => {
        window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", code: "Escape", keyCode: 27, bubbles: true }))
        return trigger.getAttribute("aria-expanded")
      })(arguments[0])
    JS
    assert_equal "false", expanded
    assert_no_selector "li[id^='comment-'] [role='menuitem']", text: "Reply", visible: true
  end

  should "keep the thread and approve affordance together on the card" do
    open_suggestion_card

    # Owner authority + pending → the card carries Approve/Reject next to
    # the thread (§12 machinery), so read-then-decide happens in one place.
    assert_selector "turbo-frame#suggestion-panel button", text: "Approve"
    assert_selector "turbo-frame#suggestion-panel button", text: "Reject"
    assert_selector "textarea[name='comment[body]']"
  end

  should "render and post on the detail page's discussion card" do
    visit framework_suggestion_path(@framework_id, @suggestion_id)
    assert_text "Discussion"

    composer = find("textarea[name='comment[body]']", match: :first)
    compose_and_submit(composer, "From the detail page")

    assert_text "From the detail page"
    assert_current_path framework_suggestion_path(@framework_id, @suggestion_id)
  end

  should "render the detail page discussion on mobile" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    ActsAsTenant.with_tenant(@tenant) do
      Frameworks::CommandHandler.new.comment_on_suggestion(
        @framework_id, @suggestion_id, SecureRandom.uuid_v7,
        body: "Seeded on mobile", author_id: @person.id.to_s
      )
    end

    visit framework_suggestion_path(@framework_id, @suggestion_id)

    assert_text "Discussion"
    assert_text "Seeded on mobile"
    assert_selector "textarea[name='comment[body]']"
  end
end
