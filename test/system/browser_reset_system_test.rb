# frozen_string_literal: true

require "application_system_test_case"

class BrowserResetSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: TEST_PASSWORD)
    ActsAsTenant.with_tenant(@tenant) { FactoryBot.create(:tenant_user, tenant: @tenant, user: @user) }
  end

  should "not let a response that lands after the reset hand the next test this session (#212)" do
    sign_in_as(@user)
    held = Queue.new
    release = Queue.new
    hold = ActiveSupport::Notifications.subscribe("start_processing.action_controller") do |*, payload|
      next unless payload[:headers]["X-Held"]

      held << :in
      release.pop
    end
    page.execute_script("fetch(arguments[0], { headers: { 'X-Held': '1' } })", assessments_path)
    assert held.pop(timeout: Capybara.default_max_wait_time), "the held request never reached the server"

    reset = page.driver.method(:reset!)
    page.driver.stub(:reset!, -> { reset.call.tap { release << :go } }) { Capybara.reset_sessions! }
    visit "/robots.txt"

    assert_empty page.driver.browser.manage.all_cookies
  ensure
    release&.push(:go)
    ActiveSupport::Notifications.unsubscribe(hold) if hold
  end
end
