# frozen_string_literal: true

# Automatically captures screenshots around Capybara actions during system tests.
# Click actions capture both before and after the click; other actions capture
# only after. This ensures transient states (e.g. a celebration prompt visible
# before "Continue" is clicked) are never missed.
#
# Gated by the SCREENSHOTS environment variable — zero overhead when disabled.
#
# Usage:
#   SCREENSHOTS=1 bin/rails test test/system/participations_system_test.rb
#
# Output:
#   tmp/screenshots/ParticipationsSystemTest/
#     full_participation_flow_should_start_submit_and_complete/
#       001_before_click_button_Done.png
#       002_after_click_button_Done.png
#       003_before_click_link_Continue.png
#       004_after_click_link_Continue.png
#       ...
#
# A namespaced class becomes a single dash-joined segment, so paths stay
# artifact-upload safe:
#   tmp/screenshots/AssessmentCycles-EvidenceReportSystemTest/...
#
# You can also call `screenshot("label")` explicitly inside any test body.
module AutoScreenshots
  extend ActiveSupport::Concern

  included do
    setup :init_auto_screenshots
  end

  # Manual screenshot — always available, not gated by ENV.
  # Uses the same directory and counter as auto-screenshots when active.
  def screenshot(label)
    ensure_screenshot_dir!
    @screenshot_index += 1
    filename = "#{@screenshot_index.to_s.rjust(3, "0")}_#{sanitize_for_filename(label)}.png"
    page.save_screenshot(@screenshot_dir.join(filename)) # rubocop:disable Lint/Debugger
  end

  private

  def init_auto_screenshots
    @screenshot_index = 0
    @screenshot_dir = nil
    @auto_screenshots = ENV["SCREENSHOTS"].present?
  end

  def ensure_screenshot_dir!
    return if @screenshot_dir

    @screenshot_dir = Rails.root.join(
      "tmp", "screenshots", screenshot_class_name, screenshot_test_name
    )
    FileUtils.mkdir_p(@screenshot_dir)
  end

  # The class-name path segment, safe for artifact upload.
  #
  # A namespaced class ("AssessmentCycles::EvidenceReportSystemTest") would
  # otherwise put a colon in the path, which actions/upload-artifact rejects —
  # and it errors the whole step, so a namespaced suite anywhere in the tree
  # loses every failure screenshot the step exists to preserve. "-" keeps the
  # namespace boundary readable where "_" would blur into a class that
  # genuinely has one.
  #
  # @return [String]
  def screenshot_class_name
    sanitize_for_filename(self.class.name.to_s.gsub("::", "-"))
  end

  def screenshot_test_name
    name = method_name.to_s
    name = name.sub(/\Atest_:?\s*/, "")
    sanitize_for_filename(name).truncate(80, omission: "")
  end

  def sanitize_for_filename(text)
    text.to_s.gsub(/[^\w-]/, "_").gsub(/_+/, "_").gsub(/\A_|_\z/, "")
  end

  def auto_screenshot(action, detail = nil)
    return unless @auto_screenshots

    label = [ action, sanitize_for_filename(detail) ].compact_blank.join("_")
    screenshot(label)
  end

  # --- Capybara action overrides ---

  def visit(path, ...)
    super.tap { auto_screenshot("visit", path) }
  end

  def click_on(locator = nil, ...)
    auto_screenshot("before_click_on", locator)
    super.tap { auto_screenshot("after_click_on", locator) }
  end

  def click_link(locator = nil, ...)
    auto_screenshot("before_click_link", locator)
    super.tap { auto_screenshot("after_click_link", locator) }
  end

  def click_button(locator = nil, ...)
    auto_screenshot("before_click_button", locator)
    super.tap { auto_screenshot("after_click_button", locator) }
  end

  def fill_in(locator, ...)
    super.tap { auto_screenshot("fill_in", locator) }
  end

  def select(value = nil, ...)
    super.tap { auto_screenshot("select", value) }
  end

  def check(locator = nil, ...)
    super.tap { auto_screenshot("check", locator) }
  end

  def uncheck(locator = nil, ...)
    super.tap { auto_screenshot("uncheck", locator) }
  end

  def choose(locator = nil, ...)
    super.tap { auto_screenshot("choose", locator) }
  end

  def attach_file(locator = nil, ...)
    super.tap { auto_screenshot("attach_file", locator) }
  end

  def accept_confirm(...)
    super.tap { auto_screenshot("accept_confirm") }
  end

  def accept_alert(...)
    super.tap { auto_screenshot("accept_alert") }
  end
end
