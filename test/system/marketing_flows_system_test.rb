# frozen_string_literal: true

require "application_system_test_case"
require "rake"
require_relative "../../lib/tasks/example_seed"
require_relative "../../lib/tasks/calibration_activity_seed"

# Walks the screens the README shows, on the seeded demo tenant, and
# captures each one. Every run proves the flows still render; only
# README_SCREENSHOTS=1 writes the captures over docs/screenshots/:
#
#   README_SCREENSHOTS=1 bin/rails test test/system/marketing_flows_system_test.rb
#
# Otherwise they land in tmp/screenshots/readme/ for a look.
class MarketingFlowsSystemTest < ApplicationSystemTestCase
  VIEWPORT = { width: 1440, height: 900, deviceScaleFactor: 2, mobile: false }.freeze
  # The README's colours: the demo tenant's own branding, not the Default theme.
  THEME = { "brand" => { "light" => "#a83265" }, "nav-surface" => { "light" => "#2b2640" } }.freeze

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @admin = create(:user, email: SeedAdmin::DEV_EMAIL, password: TEST_PASSWORD, global_admin: true)
    @tenant = ExampleSeed.new(admin_user: @admin, io: StringIO.new).call
    @tenant.update!(theme: "custom", custom_theme: THEME)
  end

  # The override outlives the test in the shared browser tab and beats
  # resize_to, so every phone-size test after this one would render at 1440.
  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  should "capture every README screen from the seeded demo" do
    framework, theo, cycle = ActsAsTenant.with_tenant(@tenant) do
      framework = FrameworkState::Framework.first
      theo = Person.find_by!(email: "theo@nullisland.example")
      [ framework, theo, AssessmentCycle.for_framework(framework.framework_id).open_cycles.first ]
    end

    sign_in_as(@admin)
    apply_viewport
    capture_framework_explorer(framework)
    capture_suggested_edits(framework)
    capture_cycle_progress(cycle)

    switch_to("marisol@nullisland.example")
    capture_assessment(theo, framework)
    capture_feedback(theo)

    session = ActsAsTenant.with_tenant(@tenant) do
      CalibrationActivitySeed.new(tenant: @tenant, io: StringIO.new).call
      CalibrationSession.sole
    end
    switch_to(@admin.email)
    capture_calibration(session)
  end

  private

  def capture_framework_explorer(framework)
    visit framework_path(framework.framework_id)
    assert_text "Code & Systems Quality"
    assert_text "Writes small, tested changes"
    capture "framework-explorer"
  end

  def capture_suggested_edits(framework)
    visit framework_suggestions_path(framework.framework_id)
    assert_text "TIER 3 — BEHAVIOURAL EXPECTATIONS"
    assert_text "Killing a slice is the harder half of slicing."
    capture "suggested-edits"
  end

  def capture_cycle_progress(cycle)
    visit cohort_assessment_cycle_path(cycle)
    assert_text "#{cycle.name} — cohort progress"
    assert_text "Progress funnel"
    capture "cycle-progress"
  end

  def capture_assessment(theo, framework)
    assignment = ActsAsTenant.with_tenant(@tenant) do
      PersonFrameworkAssignment.find_by!(person_id: theo.id, framework_id: framework.framework_id)
    end
    visit assessment_path(assignment)
    assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
    assert_text "Theo Okonkwo"
    assert_text "Code & Systems Quality"
    capture "assessment"
  end

  # The thread pane grows with the window, so no viewport fits the navbar
  # and the whole hub; scroll the page to the hub and the thread to the
  # feedback worth showing.
  def capture_feedback(theo)
    visit evidence_report_conversation_path(theo.id)
    assert_text "INCIDENT RESPONSE"
    assert_text "Growth area"
    page.execute_script(<<~JS)
      window.scrollTo(0, document.documentElement.scrollHeight);
      const card = [...document.querySelectorAll("main *")]
        .find((el) => el.innerText?.trim().startsWith("INCIDENT RESPONSE"));
      const thread = [...document.querySelectorAll("main *")]
        .filter((el) => /(auto|scroll)/.test(getComputedStyle(el).overflowY) && el.scrollHeight > el.clientHeight)
        .sort((a, b) => b.scrollHeight - a.scrollHeight)[0];
      if (card && thread) {
        thread.scrollTop = 0;
        thread.scrollTop = card.getBoundingClientRect().top - thread.getBoundingClientRect().top - 40;
      }
    JS
    capture "feedback"
  end

  def capture_calibration(session)
    visit calibration_session_path(session, view: "divergence")
    assert_text "CAPABILITY DIVERGENCE"
    assert_text "Kofi Mensah"
    page.execute_script(<<~JS)
      const tabs = document.querySelector("[role='tablist']");
      window.scrollTo(0, tabs.getBoundingClientRect().top + window.scrollY - 28);
    JS
    capture "calibration"
  end

  def switch_to(email)
    Capybara.reset_sessions!
    sign_in_as(User.find_by!(email: email))
    apply_viewport
  end

  def apply_viewport
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", **VIEWPORT)
  end

  def capture(name)
    page.evaluate_async_script("document.fonts.ready.then(() => arguments[0]())")
    wait_for_turbo_idle
    png = Base64.decode64(page.driver.browser.execute_cdp("Page.captureScreenshot", format: "png")["data"])
    write_screenshot(name, png)
  end

  def write_screenshot(name, png)
    if ENV["README_SCREENSHOTS"].present?
      path = Rails.root.join("docs/screenshots/#{name}.png")
      File.binwrite(path, png)
      quantise(path)
    else
      dir = Rails.root.join("tmp/screenshots/readme")
      FileUtils.mkdir_p(dir)
      File.binwrite(dir.join("#{name}.png"), png)
    end
  end

  # pngquant takes a capture from about 380 KB to about 100 KB; without it
  # the README still renders, just heavier.
  def quantise(path)
    return warn("[marketing flows] pngquant not found; #{path.basename} left unquantised") unless system("which pngquant > /dev/null 2>&1")

    system("pngquant", "--quality=80-95", "--speed", "1", "--strip", "--force", "--output", path.to_s, path.to_s,
      exception: true)
  end
end
