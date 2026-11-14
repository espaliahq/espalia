# frozen_string_literal: true

require "test_helper"

Dir["#{File.dirname(__FILE__)}/support/system/**/*.rb"].sort.each { |f| require f }

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # Every test signs in with TEST_PASSWORD, which is in public breach lists.
  # Chrome's leak check runs in the background, and once it reports the leak
  # Chrome drops every click and key sent to the tab for the rest of that
  # test. Whichever test is running then fails as a dropped click (#106).
  #
  # Capybara's reset parks the last page in the back-forward cache on its way
  # to about:blank, and a request that page still had open lands after the
  # reset clears cookies, handing the next test the last one's session (#212).
  test_chrome_options = lambda do |options|
    options.add_preference("profile.password_manager_leak_detection", false)
    options.add_argument("--disable-features=BackForwardCache")
  end

  if ENV["CAPYBARA_SERVER_PORT"]
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ], options: {
      browser: :remote,
      url: "http://#{ENV["SELENIUM_HOST"]}:4444"
    }, &test_chrome_options
  else
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ], &test_chrome_options
  end

  # Default to a single worker — each worker runs its own Chrome, and one short
  # of cores starves its JS event loop past Capybara's wait window. CI sizes its
  # count to its runner (.github/AGENTS.md); devcontainer compose sets 4 to fan
  # out across Selenium Grid nodes.
  parallelize(workers: ENV.fetch("SYSTEM_TEST_WORKERS", "1").to_i)

  # Each worker forks its own process and needs its own Puma port. Worker 0 uses
  # the base port; workers 1..N get base+worker. The browser (remote Selenium)
  # dials rails-app on that port.
  if ENV["CAPYBARA_SERVER_PORT"]
    Capybara.server_host = "rails-app"
    Capybara.server_port = ENV["CAPYBARA_SERVER_PORT"].to_i
    Capybara.app_host    = "http://rails-app:#{Capybara.server_port}"
  end

  parallelize_setup do |worker|
    if ENV["CAPYBARA_SERVER_PORT"]
      Capybara.server_port = ENV["CAPYBARA_SERVER_PORT"].to_i + worker
      Capybara.app_host    = "http://rails-app:#{Capybara.server_port}"
    end
  end

  class << self
    attr_accessor :browser_versions_logged
  end

  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

  # The Selenium container can be slow to respond on cold starts or under
  # load. Bump the HTTP client read/open timeouts so session creation
  # doesn't time out during the WebDriver handshake.
  Capybara.register_driver :selenium_headless_chrome do |app|
    options = Selenium::WebDriver::Chrome::Options.new
    options.add_argument("--headless=new")
    options.add_argument("--disable-gpu")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--window-size=1400,1400")
    test_chrome_options.call(options)

    client = Selenium::WebDriver::Remote::Http::Default.new
    client.read_timeout = 120
    client.open_timeout = 120

    driver_opts = { browser: :chrome, options: options, http_client: client }

    if ENV["CAPYBARA_SERVER_PORT"]
      driver_opts[:browser] = :remote
      driver_opts[:url] = "http://#{ENV["SELENIUM_HOST"]}:4444"
    end

    Capybara::Selenium::Driver.new(app, **driver_opts)
  end

  Capybara.default_driver = :selenium_headless_chrome
  Capybara.javascript_driver = :selenium_headless_chrome

  # CI runners (no Selenium grid) are slow under load — Chrome's JS event
  # loop can be starved long enough that Turbo Drive round-trips exceed even
  # a 5s wait. Bumping the default to 10s gives Turbo + Stimulus time to
  # settle without making fast-local tests slower (Capybara only waits as
  # long as needed).
  Capybara.default_max_wait_time = 10

  # Maximum number of times to retry browser session creation when the
  # Selenium container responds with a network timeout.
  BROWSER_BOOT_RETRIES = 3

  # Default password for users created via FactoryBot — used by sign_in_as.
  TEST_PASSWORD = "password123"

  # The Devise sign-in form, for the JS submit fallback. Keyed on the action
  # because the Phlex view (app/views/users/sessions/new_view.rb) gives the
  # form no id or class of its own. A miss is fatal, not silent — see
  # +submit_sign_in_form_via_js+.
  SIGN_IN_FORM_SELECTOR = "form[action*='sign_in']"

  include AutoScreenshots
  include StimulusHelpers
  include FetchStubHelpers
  include LayoutHelpers

  setup do
    with_browser_retries do
      clear_emulation
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      keep_page_focused
    end
    log_browser_versions if ENV["CI"]
  end

  # Signs the given user in via the standard Devise form. Retries the form
  # submission once if the redirect to root_path doesn't land — on slow CI
  # runners, the form-submission click can be silently dropped when Chrome's
  # JS event loop is starved (the same class of flake covered by
  # +click_with_retry+, but for the Devise sign-in form which is the entry
  # point for almost every system test).
  #
  # @param user [User] the user to sign in
  # @param password [String] defaults to +TEST_PASSWORD+
  def sign_in_as(user, password: TEST_PASSWORD)
    visit new_user_session_path

    submit_sign_in_form(user.email, password)

    # If the form click was dropped, the URL stays on /users/sign_in — fall
    # back to a JS-dispatched form submit, which bypasses Selenium pointer
    # hit-testing entirely. We detect a dropped submit by the URL never
    # moving away from the sign-in path within the wait window. (We pin on the
    # sign-in path leaving, not on root_path landing, so this stays robust
    # regardless of where a successful sign-in routes.)
    misses = []
    unless page.has_no_current_path?(new_user_session_path, wait: Capybara.default_max_wait_time)
      misses = submit_sign_in_form_via_js(user.email, password)
    end

    # Same record-then-enrich shape as the guarded click helpers: the recovery
    # reports what it could not find, and this full-wait assertion decides the
    # outcome. It replaces the zero-wait "are we still on the sign-in page?"
    # probe the fallback used to flunk behind — that probe re-opened the very
    # late-landing race it was written to close, on the suite's highest-traffic
    # helper, by turning a navigation that committed a beat later into a false
    # "Update SIGN_IN_FORM_SELECTOR".
    assert_after_recovery(misses) { assert_no_current_path new_user_session_path }
  end

  # Suppress Rails' automatic failure screenshot when the browser session
  # itself is unreachable — attempting a screenshot would create a new
  # session that also times out, producing a confusing double error.
  def take_failed_screenshot
    super
  rescue Net::ReadTimeout
    warn "[system test] Skipping failure screenshot — browser unreachable"
  end

  private

  # Ensures the browser is sitting on a freshly-rendered Devise sign-in form
  # before a sign_in attempt tries to fill its fields. Two recurring failure
  # modes this guards against:
  #
  # 1. `visit new_user_session_path` returns on a starved CI runner before
  #    the rendered page has settled — fill_in then races an empty document.
  # 2. After `Capybara.reset_sessions!` mid-test, a leftover authenticated
  #    session survived the reset; Devise then redirects /users/sign_in to
  #    root for the still-signed-in user, so the form never renders.
  #    (Surfaced in AlignmentAssessments "assessee experience during
  #    alignment" runs #27393468272 / #27490859327 / #27495673118 /
  #    #27514458883.) The back-forward cache was the cause, and is now off
  #    (#212); this stays as a backstop.
  #
  # Strategy: visit if the form isn't already on the page, wait for the
  # input to appear, and if it doesn't, explicitly delete cookies + revisit
  # before failing — covers both the timing race and the carryover-session
  # race in one place.
  def ensure_sign_in_form_loaded
    visit new_user_session_path unless page.has_field?("Email", wait: 0)
    return if page.has_selector?("input#user_email", visible: true, wait: 2)

    # The visit didn't produce a sign-in form — most likely a leftover
    # session redirected us. Force a clean slate and try once more.
    page.driver.browser.manage.delete_all_cookies
    visit new_user_session_path
    assert_selector "input#user_email", visible: true
  end

  # Re-fills email/password and clicks Log in. Idempotent — Devise's sign-in
  # form is rendered fresh on every GET, so re-filling clears any partial
  # state from a dropped first attempt.
  def submit_sign_in_form(email, password)
    ensure_sign_in_form_loaded

    fill_in "Email", with: email
    fill_in "Password", with: password
    click_button "Log in"
  end

  # Same as +submit_sign_in_form+ but submits via a JS-dispatched
  # +form.requestSubmit()+ — bypasses Selenium's synthetic pointer click
  # entirely so a starved CI runner can't drop the submission.
  #
  # @return [Array<String>] miss phrases for +assert_after_recovery+; empty
  #   when the form was found and submitted
  def submit_sign_in_form_via_js(email, password)
    ensure_sign_in_form_loaded

    # Set the credentials via JS rather than fill_in: send_keys drops
    # characters on a starved runner (see docs/guidelines/testing.md), so a
    # fallback that re-types them can submit a TRUNCATED password, fail
    # authentication, and land back on the sign-in form — indistinguishable
    # from the dropped click it exists to recover from. Assigning the values
    # makes this attempt genuinely different from the first, not a retry of
    # the same fragile input path. +js_fill_in+ is that assignment, and it
    # raises when the field is missing rather than leaving the credential
    # silently empty — the same silent-miss class this method guards below.
    js_fill_in "Email", with: email
    js_fill_in "Password", with: password

    # The script reports whether it found the form: wrapping the body in a
    # bare `if (form)` made a selector miss (a Devise route remap moving the
    # action away from `sign_in`, a Turbo-frame-wrapped form) a silent no-op.
    # sign_in_as then failed at `assert_no_current_path` with a "still on the
    # sign-in page" error attributed to the dropped click this fallback exists
    # to recover from — with no hint the recovery itself never ran.
    #
    # The selector is passed as an argument, never interpolated into the
    # script source: a selector containing a double quote would otherwise
    # break the script at JS parse time, replacing the curated flunk with a
    # cryptic SyntaxError.
    submitted = evaluate_recovery_script(<<~JS, SIGN_IN_FORM_SELECTOR)
      (() => {
        const form = document.querySelector(arguments[0]);
        if (!form) return false;

        // Pass the submitter so a named submit button's name/value would be
        // included, exactly as a real click submits it. WebIDL treats an
        // explicit `undefined` for an optional param as omitted; only null
        // is hazardous.
        const btn = form.querySelector("button[type='submit'], input[type='submit']");
        form.requestSubmit(btn ?? undefined);
        return true;
      })()
    JS

    single_stage_misses(
      submitted,
      "found no form matching #{SIGN_IN_FORM_SELECTOR.inspect} — the Devise sign-in form's " \
      "action or markup changed, so the recovery for a dropped submit click is dead. " \
      "Update SIGN_IN_FORM_SELECTOR in test/application_system_test_case.rb"
    )
  rescue Capybara::ElementNotFound
    # The credential fields are gone. Either the first submit landed after
    # all (survivable — the assertion in sign_in_as will pass) or the form
    # changed (the assertion fails and this note explains it). Reporting
    # rather than raising lets that assertion decide, with its full wait.
    [ recovery_note("found no credential field to fill — the first submit may have landed, or " \
                    "the Devise form changed") ]
  end

  # See testing.md → "Clear Any CDP Emulation You Set".
  def clear_emulation
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", media: "", features: [])
  end

  # See testing.md → "Focus Needs a Focused Page".
  def keep_page_focused
    page.driver.browser.execute_cdp("Emulation.setFocusEmulationEnabled", enabled: true)
  end

  # Once per worker, so the CI log shows which Chrome a run used.
  def log_browser_versions
    return if ApplicationSystemTestCase.browser_versions_logged

    ApplicationSystemTestCase.browser_versions_logged = true
    caps = page.driver.browser.capabilities
    warn "[system test] Chrome #{caps.browser_version}, " \
         "ChromeDriver #{caps["chrome"]&.fetch("chromedriverVersion", "unknown")}"
  end

  # Retries a block that makes the first Selenium call, rescuing the
  # Net::ReadTimeout that occurs when the Chrome container is cold or
  # overloaded. Only intended for the setup phase — mid-test timeouts
  # still fail immediately so they surface real issues.
  #
  # @param retries [Integer] number of attempts
  # @yield the block to retry
  def with_browser_retries(retries: BROWSER_BOOT_RETRIES, &block)
    attempts = 0
    begin
      attempts += 1
      yield
    rescue Net::ReadTimeout => e
      raise e if attempts >= retries

      warn "[system test] Browser session timed out (attempt #{attempts}/#{retries}), retrying..."
      Capybara.current_session.quit
      sleep 2 # Give the Selenium container time to release resources
      retry
    end
  end
end
