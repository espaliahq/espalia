# frozen_string_literal: true

require "test_helper"

Dir["#{File.dirname(__FILE__)}/support/system/**/*.rb"].sort.each { |f| require f }

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  if ENV["CAPYBARA_SERVER_PORT"]
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ], options: {
      browser: :remote,
      url: "http://#{ENV["SELENIUM_HOST"]}:4444"
    }
  else
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]
  end

  # Default to a single worker — 2-core CI runners can't sustain multiple Chrome
  # processes (starved JS event loops miss Capybara's wait window). Devcontainer
  # compose sets SYSTEM_TEST_WORKERS=2 to fan out across Selenium Grid nodes.
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

  # CI runners (especially GitHub-hosted ubuntu-latest with no Selenium grid)
  # are slow under load — Chrome's JS event loop can be starved long enough
  # that Turbo Drive round-trips exceed even a 5s wait. Bumping the default
  # to 10s gives Turbo + Stimulus time to settle without making fast-local
  # tests slower (Capybara only waits as long as needed).
  Capybara.default_max_wait_time = 10

  # Maximum number of times to retry browser session creation when the
  # Selenium container responds with a network timeout.
  BROWSER_BOOT_RETRIES = 3

  # Default password for users created via FactoryBot — used by sign_in_as.
  TEST_PASSWORD = "password123"

  include AutoScreenshots
  include StimulusHelpers

  setup do
    with_browser_retries do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    end
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
    # hit-testing entirely. has_current_path? waits up to default_max_wait_time.
    unless page.has_current_path?(root_path, wait: Capybara.default_max_wait_time)
      submit_sign_in_form_via_js(user.email, password)
    end

    assert_current_path root_path
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

  # Re-fills email/password and clicks Log in. Idempotent — Devise's sign-in
  # form is rendered fresh on every GET, so re-filling clears any partial
  # state from a dropped first attempt.
  def submit_sign_in_form(email, password)
    # If a dropped click left us mid-form, navigate back to a fresh form so
    # the field selectors are present and not stale.
    visit new_user_session_path unless page.has_field?("Email", wait: 0)

    fill_in "Email", with: email
    fill_in "Password", with: password
    click_button "Log in"
  end

  # Same as +submit_sign_in_form+ but submits via a JS-dispatched
  # +form.requestSubmit()+ — bypasses Selenium's synthetic pointer click
  # entirely so a starved CI runner can't drop the submission.
  def submit_sign_in_form_via_js(email, password)
    visit new_user_session_path unless page.has_field?("Email", wait: 0)

    fill_in "Email", with: email
    fill_in "Password", with: password
    page.execute_script(<<~JS)
      const btn = Array.from(document.querySelectorAll("button, input[type='submit']"))
        .find(el => (el.textContent.trim() || el.value) === "Log in");
      btn?.closest("form")?.requestSubmit(btn);
    JS
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
