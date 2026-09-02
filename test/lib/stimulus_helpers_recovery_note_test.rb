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
      assert_match(/misattributed to a dropped click/, error.message)
    end

    should "list every miss when several recovery steps found nothing" do
      misses = [ "the JS click recovery found no button", "the requestSubmit recovery found no button" ]

      error = assert_raises(Minitest::Assertion) do
        subject.send(:assert_after_recovery, misses) { raise Minitest::Assertion, "boom" }
      end

      misses.each { |miss| assert_match(/#{Regexp.escape(miss)}/, error.message) }
    end
  end
end
