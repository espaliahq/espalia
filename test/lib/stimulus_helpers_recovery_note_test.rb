# frozen_string_literal: true

require "test_helper"
require Rails.root.join("test/support/system/stimulus_helpers")

# Unit tests for +assert_after_recovery+, the shared record-then-enrich
# primitive behind the guarded click helpers. Both branches matter and both
# are cheap to pin here: the enriched path must keep the original assertion
# message intact (a note that REPLACED it would hide the real failure), and
# the no-miss path must leave the message untouched (a note on every failure
# is noise that trains readers to ignore it).
#
# The end-to-end proof that a recovery step actually reports its miss lives in
# test/system/click_recovery_note_system_test.rb — that one needs a browser.
class StimulusHelpersRecoveryNoteTest < ActiveSupport::TestCase
  # Browser-less include target for the helper under test.
  class Host
    include StimulusHelpers
  end

  subject { Host.new }

  context "#assert_after_recovery" do
    should "return the block's value when the assertion passes" do
      assert_equal :ok, subject.send(:assert_after_recovery, []) { :ok }
    end

    should "re-raise unchanged when no recovery step missed" do
      error = assert_raises(Minitest::Assertion) do
        subject.send(:assert_after_recovery, []) { raise Minitest::Assertion, "expected text" }
      end

      assert_equal "expected text", error.message
    end

    should "append the miss note while preserving the original message" do
      error = assert_raises(Minitest::Assertion) do
        subject.send(:assert_after_recovery, [ 'the JS recovery found no <a> matching "Save"' ]) do
          raise Minitest::Assertion, "expected to find text \"Saved\""
        end
      end

      assert_match(/expected to find text "Saved"/, error.message)
      assert_match(/the JS recovery found no <a> matching "Save"/, error.message)
    end

    should "run the signal ladder when given no block" do
      host = Class.new(Host) do
        attr_reader :asserted

        def assert_text(text, **) = @asserted = [ :text, text ]
        def assert_selector(sel, **) = @asserted = [ :selector, sel ]
        def assert_no_text(text, **) = @asserted = [ :no_text, text ]
      end.new

      host.send(:assert_after_recovery, [], expect_selector: "#badge")

      assert_equal [ :selector, "#badge" ], host.asserted
    end

    should "list every miss when several recovery steps found nothing" do
      misses = [ "the JS click recovery found no button", "the requestSubmit recovery found no button" ]

      error = assert_raises(Minitest::Assertion) do
        subject.send(:assert_after_recovery, misses) { raise Minitest::Assertion, "boom" }
      end

      misses.each { |miss| assert_match(/#{Regexp.escape(miss)}/, error.message) }
    end
  end

  context "#dispatch_misses" do
    should "report nothing when both dispatches found the toggle" do
      assert_empty subject.send(:dispatch_misses, "#toggle", true, true)
    end

    should "name the re-dispatch when only it missed" do
      note = subject.send(:dispatch_misses, "#toggle", true, false).sole

      assert note.start_with?(StimulusHelpers::RECOVERY_NOTE_PREFIX), note
      assert_match(/the re-dispatch matched nothing for "#toggle"/, note)
      assert_match(/Turbo Frame replacement likely detached it/, note)
    end

    should "call a first-dispatch miss a re-render when the re-dispatch found it" do
      note = subject.send(:dispatch_misses, "#toggle", false, true).sole

      assert_match(/the first JS dispatch matched nothing/, note)
      assert_match(/a frame re-render, not a missing element/, note)
      # The element was found, so detachment is the wrong conclusion here.
      assert_no_match(/detached/, note)
    end

    should "report both when neither dispatch found the toggle" do
      note = subject.send(:dispatch_misses, "#toggle", false, false).sole

      assert_match(/both JS dispatches matched nothing/, note)
      assert_match(/likely detached it/, note)
    end

    context "when no re-dispatch was needed" do
      should "report nothing when the only dispatch found the toggle" do
        assert_empty subject.send(:dispatch_misses, "#toggle", true, :skipped)
      end

      should "name the single dispatch when it missed" do
        note = subject.send(:dispatch_misses, "#toggle", false, :skipped).sole

        assert_match(/the JS dispatch matched nothing for "#toggle"/, note)
      end
    end

    should "say the dispatch could not run when the document was replaced" do
      note = subject.send(:dispatch_misses, "#toggle", :unavailable, :skipped).sole

      assert_match(/could not run/, note)
    end
  end

  context "#rating_misses" do
    should "report nothing when the popover form was submitted" do
      assert_empty subject.send(:rating_misses, "#rating-1", "Most", "submitted")
    end

    should "distinguish a popover that never opened from a missing form" do
      no_item = subject.send(:rating_misses, "#rating-1", "Most", "no-item").sole
      no_form = subject.send(:rating_misses, "#rating-1", "Most", "no-form").sole

      assert_match(/no menu item containing "Most"/, no_item)
      assert_match(/popover may not have opened/, no_item)
      assert_match(/outside any <form>/, no_form)
    end

    should "name a rating cell that was not on the page" do
      note = subject.send(:rating_misses, "#rating-1", "Most", "no-wrapper").sole

      assert_match(/the rating cell "#rating-1" was not on the page/, note)
    end
  end

  context "#single_stage_misses" do
    should "report nothing when the stage acted" do
      assert_empty subject.send(:single_stage_misses, true, "found no <a>")
    end

    should "carry the caller's phrase when the stage found nothing" do
      assert_match(/found no <a>/, subject.send(:single_stage_misses, false, "found no <a>").sole)
    end

    should "override the phrase when the script could not run" do
      note = subject.send(:single_stage_misses, :unavailable, "found no <a>").sole

      assert_match(/could not run/, note)
      assert_no_match(/found no <a>/, note)
    end
  end

  context "#button_misses" do
    should "report nothing when the JS click stage acted" do
      assert_empty subject.send(:button_misses, "Save", true, "no-form")
      assert_empty subject.send(:button_misses, "Save", true, "no-button")
      assert_empty subject.send(:button_misses, "Save", true, "submitted")
    end

    should "call a stage-1 miss a late render when requestSubmit submitted" do
      note = subject.send(:button_misses, "Save", false, "submitted").sole

      assert_match(/likely rendered late/, note)
      # requestSubmit worked, so drift is the wrong conclusion.
      assert_no_match(/drifted/, note)
    end

    should "blame drift only when neither stage found the button" do
      note = subject.send(:button_misses, "Save", false, "no-button").sole

      assert_match(/neither stage found a button matching "Save"/, note)
      assert_match(/locator has likely drifted/, note)
    end

    should "say the recovery could not run when the document was replaced" do
      note = subject.send(:button_misses, "Save", :unavailable, :unavailable).sole

      assert_match(/could not run/, note)
      assert_match(/not a locator problem/, note)
    end

    should "distinguish a button that sits outside any form" do
      note = subject.send(:button_misses, "Save", false, "no-form").sole

      assert_match(/neither stage acted/, note)
      assert_match(/outside any <form>/, note)
    end
  end
end
