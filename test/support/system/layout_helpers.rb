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

  # Asserts no control in the viewport hands a tap on its own face to a
  # neighbouring Kit::Button's invisible 44px hit area, on two reads in a row.
  # A point on the neighbour's visible face doesn't count: that is layout
  # overlap, and a sticky header covers what scrolls under it either way.
  #
  # @param message [String] what the stolen tap means for this page
  # @return [void]
  def assert_no_stolen_taps(message = "a button's hit area takes a tap meant for its neighbour")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Capybara.default_max_wait_time
    clean_in_a_row = 0
    stolen = []
    while clean_in_a_row < 2 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      stolen = page.evaluate_script(STOLEN_TAPS_SCRIPT)
      clean_in_a_row = stolen.empty? ? clean_in_a_row + 1 : 0
      sleep 0.05 if clean_in_a_row < 2
    end
    assert_equal 2, clean_in_a_row, "#{message}: #{stolen.join('; ')}"
  end

  STOLEN_TAPS_SCRIPT = <<~JS
    (() => {
      const HIT = '[class*="after:min-h-11"]';
      const name = (el) => `${el.tagName.toLowerCase()} "${(el.getAttribute("aria-label") || el.textContent).trim().slice(0, 40)}"`;
      const controls = document.querySelectorAll("a[href], button, input:not([type=hidden]), select, textarea, summary, [role=button]");
      const stolen = new Set();
      for (const el of controls) {
        const r = el.getBoundingClientRect();
        if (r.width < 4 || r.height < 4 || r.bottom < 0 || r.top > innerHeight) continue;
        const points = [[r.left + 1, r.top + 1], [r.right - 1, r.top + 1], [r.left + 1, r.bottom - 1], [r.right - 1, r.bottom - 1],
                        [r.left + r.width / 2, r.top + 1], [r.left + r.width / 2, r.bottom - 1],
                        [r.left + 1, r.top + r.height / 2], [r.right - 1, r.top + r.height / 2]];
        for (const [x, y] of points) {
          if (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) continue;
          const thief = document.elementFromPoint(x, y)?.closest(HIT);
          if (!thief || thief === el || el.contains(thief) || thief.contains(el)) continue;
          const t = thief.getBoundingClientRect();
          if (x < t.left || x > t.right || y < t.top || y > t.bottom) stolen.add(`${name(el)} <- ${name(thief)}`);
        }
      }
      return [...stolen];
    })()
  JS
  private_constant :STOLEN_TAPS_SCRIPT
end
