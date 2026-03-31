# frozen_string_literal: true

require "test_helper"

Dir["#{File.dirname(__FILE__)}/support/system/**/*.rb"].sort.each { |f| require f }

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  if ENV["CAPYBARA_SERVER_PORT"]
    served_by host: "rails-app", port: ENV["CAPYBARA_SERVER_PORT"]

    driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ], options: {
      browser: :remote,
      url: "http://#{ENV["SELENIUM_HOST"]}:4444"
    }
  else
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]
  end

  # CI runners (2 cores) can't sustain multiple Chrome processes — JavaScript
  # event loops get starved, causing Stimulus actions to miss Capybara's wait window.
  if ENV["CI"]
    parallelize(workers: 1)
  else
    parallelize(workers: 2)
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

  # CI runners can be slow — the default 2s is too tight for Turbo round-trips.
  Capybara.default_max_wait_time = 5

  # Maximum number of times to retry browser session creation when the
  # Selenium container responds with a network timeout.
  BROWSER_BOOT_RETRIES = 3

  include AutoScreenshots
  include StimulusHelpers

  setup do
    with_browser_retries do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    end
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
