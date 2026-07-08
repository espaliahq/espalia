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

  # Submits the composer/reply form wrapping the given textarea via
  # requestSubmit — the pointer-click on small thread buttons is exactly the
  # dropped-click class testing.md's inline-editor rule exists for.
  def submit_form_of(textarea)
    page.execute_script("arguments[0].closest('form').requestSubmit();", textarea)
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

  should "post and reply from the pane's suggestion card with one-indent display" do
    open_suggestion_card

    # URL carries the focus so the card is shareable.
    assert_includes current_url, "focus=suggestion"
    assert_includes current_url, "suggestion_id=#{@suggestion_id}"

    composer = find("textarea[name='comment[body]']", match: :first)
    composer.set("Is 'long-term' the right frame?")
    submit_form_of(composer)
    assert_text "Is 'long-term' the right frame?"

    # Reply via the comment kebab — one level of indent on the reply card.
    open_dropdown(scope: "li[id^='comment-']")
    within("li[id^='comment-']", match: :first) { click_on "Reply" }
    # The reply form's visibility is the click's success signal (a
    # placeholder isn't page text, so assert on the revealed control).
    reply_box = find("textarea[placeholder='Reply…']", visible: true)
    reply_box.set("I think it is")
    submit_form_of(reply_box)
    assert_text "I think it is"
    assert_selector "li.pl-5", text: /I think it is/

    # Back to the feed — the entry now advertises the discussion.
    click_with_retry(expect_text: "All framework activity") do
      click_on "← Back to activity"
    end
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
    composer.set("From the detail page")
    submit_form_of(composer)

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
