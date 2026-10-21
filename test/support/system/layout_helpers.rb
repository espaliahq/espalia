# frozen_string_literal: true

# Page-level layout checks for responsive system tests.
module LayoutHelpers
  # Asserts the page fits its width on two reads in a row, polling until it
  # does: one read can land before async layout work (an observer, a frame
  # load) has settled, and two in a row rule out a layout that flips back.
  #
  # @param message [String] what the overflow means for this page
  # @return [void]
  def assert_no_sideways_overflow(message = "the page scrolls sideways")
    script = "[document.documentElement.scrollWidth, document.documentElement.clientWidth]"
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Capybara.default_max_wait_time
    fits_in_a_row = 0
    last_overflow = nil
    while fits_in_a_row < 2 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      scroll, client = page.evaluate_script(script)
      if scroll <= client
        fits_in_a_row += 1
      else
        fits_in_a_row = 0
        last_overflow = "scrollWidth #{scroll} > clientWidth #{client}"
      end
      sleep 0.05 if fits_in_a_row < 2
    end
    assert_equal 2, fits_in_a_row, "#{message} (#{last_overflow})"
  end
end
