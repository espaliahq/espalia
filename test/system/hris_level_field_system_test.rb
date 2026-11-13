# frozen_string_literal: true

require "application_system_test_case"

# Choosing the HRIS level field by name instead of pasting its id (#67).
class HrisLevelFieldSystemTest < ApplicationSystemTestCase
  FRAME = "turbo-frame##{Views::Integrations::HrisLevelFieldFrame::FRAME_ID}".freeze
  PICKER = "#hris_connection_level_field_id"

  FIELDS = [
    Hris::Field.new(id: "work.customColumns.column_test_id", name: "Level", kind: :text),
    Hris::Field.new(id: "work.customColumns.column_grade", name: "Grade", kind: :list),
    Hris::Field.new(id: "work.department", name: "Department", kind: :list)
  ].freeze

  setup do
    @tenant = FactoryBot.create(:tenant, :with_hibob_config)
    @admin_user = FactoryBot.create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
    end
  end

  # Answers the frame's catalogue read, on the server thread too.
  def with_catalogue(fields = FIELDS, error: nil, &)
    adapter = Object.new
    adapter.define_singleton_method(:field_catalogue) { error ? raise(error) : fields }
    Hris::BaseAdapter.stub(:for, adapter, &)
  end

  def open_connection_settings
    visit tenant_integration_path("hris")
    assert_text "Connection settings"
    load_level_field
  end

  # A lazy frame loads once it is on screen, which a phone reaches by scrolling.
  # Waiting for it also keeps the load inside the catalogue stub, so the real
  # client never reaches HiBob.
  def load_level_field
    page.execute_script("document.querySelector('#{FRAME}').scrollIntoView({ block: 'center' })")
    assert_selector "#{FRAME}[complete]", visible: :all
  end

  { "desktop" => DESKTOP_SIZE, "mobile" => MOBILE_SIZE }.each do |viewport, size|
    context "at #{viewport}" do
      setup do
        page.driver.browser.manage.window.resize_to(*size)
        sign_in_as(@admin_user)
      end

      should "choose the level field by name and save it as the field's id" do
        with_catalogue do
          open_connection_settings
          picker = find(PICKER)
          assert_equal "work.customColumns.column_test_id", picker.value
          assert_equal [ "None", "Department · list", "Grade · list", "Level · text" ],
                       picker.all("option").map(&:text)
          assert_no_sideways_overflow
          screenshot("level_field_picker_#{viewport}")

          picker.select("Grade · list")
          assert_equal "work.customColumns.column_grade", evaluate_script("document.querySelector('#{PICKER}').value")
          click_button_with_js_fallback "Save connection", expect_text: "HRIS connection saved."
          load_level_field
        end

        assert_equal "work.customColumns.column_grade", @tenant.reload.hris_config.level_field_id
        assert_text "work.customColumns.column_grade" # the configuration summary
        screenshot("level_field_saved_#{viewport}")
      end
    end
  end

  context "at desktop" do
    setup do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      sign_in_as(@admin_user)
    end

    should "keep the stored field when the HRIS can't be read" do
      with_catalogue(error: Hris::Hibob::Errors::ApiError.new(status: 503, body: "down")) do
        open_connection_settings
        within(FRAME) { assert_text "The HRIS did not answer as expected" }
        assert_no_selector PICKER
        screenshot("level_field_unavailable")

        js_fill_in "Service user id", with: "svc-renewed"
        click_button_with_js_fallback "Save connection", expect_text: "HRIS connection saved."
        load_level_field
      end

      assert_equal "work.customColumns.column_test_id", @tenant.reload.hris_config.level_field_id
    end

    should "clear the level field with None" do
      with_catalogue do
        open_connection_settings
        find(PICKER).select("None")
        click_button_with_js_fallback "Save connection", expect_text: "HRIS connection saved."
        load_level_field
      end

      assert_nil @tenant.reload.hris_config.level_field_id
    end
  end
end
