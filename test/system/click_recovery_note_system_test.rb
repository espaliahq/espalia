# frozen_string_literal: true

require "application_system_test_case"

# Proves the guarded click helpers report a recovery step that found no
# target, end to end through the browser.
#
# Why this needs a browser: the unit test
# (test/lib/stimulus_helpers_recovery_note_test.rb) pins the enrichment
# primitive, but only a real page can prove the JS finder actually returns
# false on a miss and that the miss reaches the failure message.
#
# The scenario is locator drift, staged deterministically: an injected <a>
# that Capybara resolves BY ID while its visible text says something else.
# The pointer click therefore lands, but the fallback's textContent match
# finds nothing — exactly what happens when a link's label changes
# ("Save settings" → "Save changes") while a test still names the old one.
class ClickRecoveryNoteSystemTest < ApplicationSystemTestCase
  # No signal this string could ever satisfy — the helper's final assertion
  # is guaranteed to fail, which is the branch under test.
  ABSENT_TEXT = "ZZ_SIGNAL_THAT_NEVER_APPEARS_ZZ"

  setup do
    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { FactoryBot.create(:tenant_user, tenant: @tenant, user: @user) }

    sign_in_as(@user)
  end

  context "click_link_with_js_fallback" do
    should "name the missed JS recovery in the failure when the locator drifted" do
      visit root_path
      assert_text "Home"

      # Findable by id, invisible to a textContent match — the drift.
      page.execute_script(<<~JS)
        const a = document.createElement("a");
        a.id = "drifted-link";
        a.href = "#";
        a.textContent = "Some other label";
        document.querySelector("body").appendChild(a);
      JS

      error = assert_raises(Minitest::Assertion) do
        click_link_with_js_fallback("drifted-link", expect_text: ABSENT_TEXT)
      end

      # The original assertion failure survives...
      assert_match(/#{Regexp.escape(ABSENT_TEXT)}/, error.message)
      # ...and now carries the recovery note, under its shared cue.
      assert_match(/#{Regexp.escape(StimulusHelpers::RECOVERY_NOTE_PREFIX)}/, error.message)
      assert_match(/found no <a> matching "drifted-link"/, error.message)
    end
  end
end
