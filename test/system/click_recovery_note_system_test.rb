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
# The scenario is "the recovery's target is gone", staged deterministically:
# an injected <a> that removes itself on click. Capybara's pointer click
# lands and consumes the element, the signal never appears, and the fallback
# then finds nothing to click — the same shape as a locator that drifted out
# from under the recovery ("Save settings" → "Save changes").
#
# Note it can NOT be staged as "findable by id, different visible text" any
# more: the finder now mirrors Capybara's resolution (id and title as well as
# text), so it would succeed by id — which is the point of that fix.
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
    should "name the missed JS recovery in the failure when its target is gone" do
      visit root_path
      assert_text "Home"

      # Consumed by the pointer click, so the recovery finds nothing.
      page.execute_script(<<~JS)
        const a = document.createElement("a");
        a.href = "#";
        a.textContent = "Vanishing link";
        a.addEventListener("click", (e) => { e.preventDefault(); a.remove(); });
        document.querySelector("body").appendChild(a);
      JS

      error = assert_raises(Minitest::Assertion) do
        click_link_with_js_fallback("Vanishing link", expect_text: ABSENT_TEXT)
      end

      # The original assertion failure survives...
      assert_match(/#{Regexp.escape(ABSENT_TEXT)}/, error.message)
      # ...and now carries the recovery note, under its shared cue.
      assert_match(/#{Regexp.escape(StimulusHelpers::RECOVERY_NOTE_PREFIX)}/, error.message)
      assert_match(/found no <a> matching "Vanishing link"/, error.message)
    end
  end
end
