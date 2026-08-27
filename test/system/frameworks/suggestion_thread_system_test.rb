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

    assert_selector "[data-clipboard-target='idle']", visible: true
    assert_no_selector "[data-clipboard-target='copied']", visible: true

    page.execute_script("document.querySelector(\"[aria-label='Copy a link to this discussion']\").click()")

    assert_selector "[data-clipboard-target='copied']", visible: true
    assert_no_selector "[data-clipboard-target='idle']", visible: true

    # Restores after the flash — with the link icon still present, not wiped.
    assert_selector "[data-clipboard-target='idle']", visible: true
    assert_no_selector "[data-clipboard-target='copied']", visible: true
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
    open_dropdown(scope: "li[id^='comment-']")
    reply_item = find("li[id^='comment-'] [role='menu'] button", text: "Reply", visible: :all)
    page.execute_script("arguments[0].click()", reply_item)
    # The reply form's visibility is the click's success signal (a
    # placeholder isn't page text, so assert on the revealed control).
    reply_box = find("textarea[placeholder='Reply…']", visible: true)
    compose_and_submit(reply_box, "I think it is")
    assert_text "I think it is"
    assert_selector "li.pl-5", text: /I think it is/

    # Back to the feed — the entry now advertises the discussion.
    click_link_with_js_fallback("← Back to activity", expect_text: "All framework activity")
    assert_text "2 · I think it is"
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
