# frozen_string_literal: true

# Stubs `window.fetch` in system tests so a specific request can be made to
# fail — or to hang — deterministically, without a sleep or a timing guess.
#
# Transport failures (a dropped connection, a 5xx HTML body, a proxy's
# text/plain 502) and in-flight windows are exactly what the `submit-fallback`,
# `submit-guard`, and `frame-error` controllers exist for, and none of them can
# be exercised from the server side.
#
# Usage:
#   patch_fetch("/evidence_modal", respond: :reject, once: true)
#   open_the_thing
#   assert_selector "#…-error", visible: true
#   click_retry            # `once: true` lets the second attempt through
#
#   patch_fetch("/evidence_requests", respond: :delay)
#   submit
#   assert_selector "button[type=submit][disabled]"   # genuinely still in flight
#   page.execute_script("window.__releaseFetch();")   # let it land
module FetchStubHelpers
  # Patch `window.fetch` so matching requests (URL contains `fragment`) are
  # answered per `respond`; everything else passes through. Matches are counted
  # in `window.__matched`, and `window.__unpatchFetch()` restores the real
  # fetch, so a test can prove its retry genuinely lands.
  #
  # Patches never STACK: a second call unpatches first, so `of` always closes
  # over the real fetch. Stacking made `__unpatchFetch` restore the *previous
  # stub* rather than the browser's fetch, and silently reset `__matched`
  # mid-test — both failures a passing assertion would happily hide.
  #
  # @param fragment [String] substring matched against the request URL
  # @param respond [Symbol, String] :error_500 — a 500 with an HTML body (the
  #   page-destroying class Turbo would otherwise render as the page);
  #   :reject — the network layer, no response at all;
  #   :delay — hold the request open until `window.__releaseFetch()`;
  #   a String — a 500 carrying that body, with `content_type`
  # @param once [Boolean] patch only the FIRST match, so a retry can succeed
  # @param content_type [String] response type for a String body — text/html
  #   reaches Turbo's frame handling, anything else is discarded by it silently
  # @return [void]
  def patch_fetch(fragment, respond: :error_500, once: false, content_type: "text/html")
    body = respond.is_a?(String) ? respond : "<html><body>Internal Server Error</body></html>"
    answer =
      case respond
      when :reject then 'Promise.reject(new TypeError("Failed to fetch"))'
      # Every held request queues its own resolver, so `__releaseFetch()`
      # settles ALL of them (in the order they were held). Assigning a single
      # resolver instead stranded every held request but the last — invisible
      # unless the test happened to assert on the one that got dropped.
      when :delay  then "new Promise((res, rej) => { " \
                        "window.__heldFetches.push(() => of(url, ...a).then(res, rej)); })"
      else "Promise.resolve(new Response(#{body.to_json}, " \
           "{ status: 500, headers: { \"Content-Type\": #{content_type.to_json} } }))"
      end

    page.execute_script(<<~JS)
      window.__unpatchFetch?.();
      const of = window.fetch;
      window.__unpatchFetch = () => { window.fetch = of; };
      window.__heldFetches = window.__heldFetches || [];
      window.__releaseFetch = () => {
        const held = window.__heldFetches;
        window.__heldFetches = [];
        held.forEach((send) => send());
      };
      window.__matched = 0;
      let spent = false;
      window.fetch = (url, ...a) => {
        if (!String(url).includes(#{fragment.to_json})) return of(url, ...a);
        if (#{once.to_json} && spent) return of(url, ...a);
        spent = true;
        window.__matched++;
        return #{answer};
      };
    JS
  end

  # Wait until exactly `count` matching requests have left the page, then
  # assert it. The stub bumps `__matched` synchronously, but Turbo only reaches
  # `fetch` a microtask or more after a submit dispatches — so a bare
  # `evaluate_script` straight after one reads 0 and proves nothing. Use this
  # whenever the count is the evidence that an action reached the server
  # (rather than following an assertion that already round-tripped).
  #
  # @param count [Integer] expected number of matched requests
  # @return [void]
  def assert_fetch_matched(count)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Capybara.default_max_wait_time
    matched = page.evaluate_script("window.__matched")
    while matched < count && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      sleep 0.05
      matched = page.evaluate_script("window.__matched")
    end
    assert_equal count, matched
  end
end
