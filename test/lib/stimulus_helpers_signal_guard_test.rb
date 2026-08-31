# frozen_string_literal: true

require "test_helper"
require Rails.root.join("test/support/system/stimulus_helpers")

# Unit tests for the "exactly one success signal" contract on the guarded
# click helpers. A call passing two signals used to have all but the first
# silently ignored (never armed, never asserted) — the disarmed-fallback bug
# the helpers exist to catch, reintroduced through the ignored argument.
#
# No browser here: the guard must run BEFORE any page interaction, so the
# host below raises if `page` is touched. A test that reached the browser
# would fail with that message instead of the expected ArgumentError.
class StimulusHelpersSignalGuardTest < ActiveSupport::TestCase
  class Host
    include StimulusHelpers

    def page
      raise "page was touched before the signal guard ran"
    end
  end

  subject { Host.new }

  context "click_with_retry" do
    should "raise when no signal is given" do
      error = assert_raises(ArgumentError) { subject.click_with_retry }
      assert_match(/click_with_retry: pass exactly one of/, error.message)
      assert_match(/given: none/, error.message)
    end

    should "raise when both signals are given" do
      error = assert_raises(ArgumentError) do
        subject.click_with_retry(expect_text: "Saved", expect_selector: "#draft-badge")
      end
      assert_match(/expect_text: \+ expect_selector:/, error.message)
    end
  end

  context "click_link_with_js_fallback" do
    should "raise when no signal is given" do
      error = assert_raises(ArgumentError) { subject.click_link_with_js_fallback("Save") }
      assert_match(/click_link_with_js_fallback: pass exactly one of/, error.message)
    end

    should "raise when both signals are given" do
      error = assert_raises(ArgumentError) do
        subject.click_link_with_js_fallback("Save", expect_text: "Saved", expect_selector: "#badge")
      end
      assert_match(/silently ignored/, error.message)
    end
  end

  context "click_selector_with_js_fallback" do
    should "raise when no signal is given" do
      error = assert_raises(ArgumentError) { subject.click_selector_with_js_fallback("a.dot") }
      assert_match(/click_selector_with_js_fallback: pass exactly one of/, error.message)
    end

    should "raise when both signals are given" do
      error = assert_raises(ArgumentError) do
        subject.click_selector_with_js_fallback("a.dot", expect_text: "Saved", expect_selector: "#badge")
      end
      assert_match(/expect_text: \+ expect_selector:/, error.message)
    end
  end

  context "click_button_with_js_fallback" do
    should "raise when no signal is given" do
      error = assert_raises(ArgumentError) { subject.click_button_with_js_fallback("Save") }
      assert_match(
        /pass exactly one of expect_text:, expect_selector:, expect_no_text:/,
        error.message
      )
    end

    should "raise when an appearance and a disappearance signal are combined" do
      error = assert_raises(ArgumentError) do
        subject.click_button_with_js_fallback(
          "Stop impersonating", expect_text: "Saved", expect_no_text: "Viewing as"
        )
      end
      assert_match(/expect_text: \+ expect_no_text:/, error.message)
    end

    should "raise when all three signals are given" do
      error = assert_raises(ArgumentError) do
        subject.click_button_with_js_fallback(
          "Save", expect_text: "Saved", expect_selector: "#badge", expect_no_text: "Draft"
        )
      end
      assert_match(/expect_text: \+ expect_selector: \+ expect_no_text:/, error.message)
    end
  end
end
