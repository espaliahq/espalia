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
# more: the finder mirrors Capybara's resolution (id and title as well as
# text), so it would succeed by id — which is the point of that fix.
#
# This test proves WIRING, not timing, so both waits are shrunk (see
# +landed_wait+ and the +using_wait_time+ below) and it signs nobody in:
# every second spent here is spent on every CI run forever.
class ClickRecoveryNoteSystemTest < ApplicationSystemTestCase
  # No signal this string could ever satisfy — the helper's final assertion
  # is guaranteed to fail, which is the branch under test.
  ABSENT_TEXT = "ZZ_SIGNAL_THAT_NEVER_APPEARS_ZZ"

  # The dropped-click window. Real value is 8s of pure waiting here.
  def landed_wait = 0.5

  context "click_link_with_js_fallback" do
    should "name the missed JS recovery in the failure when its target is gone" do
      # The unauthenticated Devise form is the cheapest real page we have —
      # no factories, no sign-in, and the helper never looks at the content.
      visit new_user_session_path
      assert_selector "input#user_email"

      # Consumed by the pointer click, so the recovery finds nothing.
      page.execute_script(<<~JS)
        const a = document.createElement("a");
        a.href = "#";
        a.textContent = "Vanishing link";
        a.addEventListener("click", (e) => { e.preventDefault(); a.remove(); });
        document.querySelector("body").appendChild(a);
      JS

      error = assert_raises(Minitest::Assertion) do
        # Shrinks the final assertion's wait, which reads Capybara's default.
        Capybara.using_wait_time(1) do
          click_link_with_js_fallback("Vanishing link", expect_text: ABSENT_TEXT)
        end
      end

      # The original assertion failure survives...
      assert_match(/#{Regexp.escape(ABSENT_TEXT)}/, error.message)
      # ...and now carries the recovery note, under its shared cue.
      assert_match(/#{Regexp.escape(StimulusHelpers::RECOVERY_NOTE_PREFIX)}/, error.message)
      assert_match(/found no <a> matching "Vanishing link"/, error.message)
    end
  end
end
