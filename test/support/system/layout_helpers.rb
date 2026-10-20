# frozen_string_literal: true

# Page-level layout checks for responsive system tests.
module LayoutHelpers
  # Asserts the page does not scroll sideways once its layout has settled.
  # A single read can land mid-reflow: CI once caught the framework explorer
  # with a 15px scrollbar (scrollWidth 375, clientWidth 360) that its own
  # failure screenshot, taken a moment later, no longer showed.
  #
  # @param message [String] what the overflow means for this page
  # @return [void]
  def assert_no_sideways_overflow(message = "no sideways overflow")
    script = "[document.documentElement.scrollWidth, document.documentElement.clientWidth]"
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Capybara.default_max_wait_time
    scroll, client = page.evaluate_script(script)
    while scroll > client && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      sleep 0.05
      scroll, client = page.evaluate_script(script)
    end
    assert_operator scroll, :<=, client, "#{message} (scrollWidth #{scroll} > clientWidth #{client})"
  end
end
