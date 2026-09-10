# frozen_string_literal: true

# Assertions for the framework explorer's ONE write-response contract
# ({Frameworks::WriteResponse}): every edit-mode write answers a Turbo Stream
# carrying exactly one toast plus the fragments for the rows it touched — never
# a redirect, never a `head :no_content`, and never a full matrix refresh.
#
# Kept in one place because "did this write navigate?" is the whole point of the
# contract: a test that only asserts the domain effect would pass just as
# happily against the old redirect.
module ExplorerWriteStreamAssertions
  TOAST_TARGET = "framework-write-status"

  # @param message [String, Regexp, nil] the toast copy (its applied-vs-proposed
  #   wording is load-bearing — nothing else on screen says which happened)
  # @param status [Symbol] :ok for a successful write, :unprocessable_content
  #   for a refused one (which stays in the same region rather than navigating)
  def assert_write_toast(message = nil, status: :ok)
    assert_response status
    assert_equal Mime[:turbo_stream].to_s, response.media_type
    assert_turbo_stream_action("update", TOAST_TARGET)
    return if message.nil?

    assert_match(message.is_a?(Regexp) ? message : /#{Regexp.escape(message)}/, response.body)
  end

  # @param action [String] "replace" / "append" / "before" / "remove"
  # @param target [String] the DOM id the fragment addresses
  def assert_turbo_stream_action(action, target, count: 1)
    assert_select %(turbo-stream[action="#{action}"][target="#{target}"]), count: count
  end

  # The write must not have navigated. Deliberately does NOT assert on `flash`:
  # the sign-in flash from the test's own `sign_in` is still in the session, and
  # a stream response can't be a redirect anyway — that is the whole assertion.
  def assert_no_navigation
    assert_not response.redirect?, "expected a Turbo Stream response, got a redirect"
  end
end

class ActionDispatch::IntegrationTest
  include ExplorerWriteStreamAssertions
end
