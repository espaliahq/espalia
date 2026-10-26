# frozen_string_literal: true

# Page-level layout checks for responsive system tests.
module LayoutHelpers
  # Waits until the page's scroll position holds on three reads in a row, so
  # a smooth scroll the page started on load (to a focused card) has ended.
  # A fixed-position dropdown closes on any scroll; open one only after this.
  #
  # @return [void]
  def wait_for_scroll_to_settle
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Capybara.default_max_wait_time
    readings = []
    until readings.size >= 3 && readings.last(3).uniq.size == 1
      flunk "the page never stopped scrolling" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      readings << page.evaluate_script("window.scrollY")
      sleep 0.15
    end
  end

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
      const off = document.createElement("style");
      off.textContent = "[data-probe-off]::after { display: none !important; }";
      document.head.append(off);
      for (const el of controls) {
        const r = el.getBoundingClientRect();
        if (r.width < 4 || r.height < 4 || r.bottom < 0 || r.top > innerHeight) continue;
        // Every 6px along each edge, inset past a rounded corner, which
        // elementFromPoint treats as outside the element.
        const points = [];
        for (let x = r.left + 3; x <= r.right - 3; x += 6) points.push([x, r.top + 2], [x, r.bottom - 2]);
        for (let y = r.top + 3; y <= r.bottom - 3; y += 6) points.push([r.left + 2, y], [r.right - 2, y]);
        for (const [x, y] of points) {
          if (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) continue;
          const thief = document.elementFromPoint(x, y)?.closest(HIT);
          if (!thief || thief === el || el.contains(thief) || thief.contains(el)) continue;
          const t = thief.getBoundingClientRect();
          if (x >= t.left && x <= t.right && y >= t.top && y <= t.bottom) continue;
          // Only a tap that would have reached el: a point a scrim or a
          // scroll container's clip already hides is nobody's to steal.
          // Hit areas can stack, so switch each one off until the point
          // lands on something that isn't one.
          const switchedOff = [];
          let beneath;
          for (let next = thief; next && !switchedOff.includes(next); next = beneath?.closest(HIT)) {
            next.setAttribute("data-probe-off", "");
            switchedOff.push(next);
            beneath = document.elementFromPoint(x, y);
            if (!beneath || beneath === el || el.contains(beneath)) break;
          }
          switchedOff.forEach((area) => area.removeAttribute("data-probe-off"));
          if (beneath && (beneath === el || el.contains(beneath))) stolen.add(`${name(el)} <- ${name(thief)}`);
        }
      }
      off.remove();
      return [...stolen];
    })()
  JS
  private_constant :STOLEN_TAPS_SCRIPT
end
