# frozen_string_literal: true

require "application_system_test_case"

# What an HRIS field would give before an admin chooses it (#107).
class HrisFieldPreviewSystemTest < ApplicationSystemTestCase
  FRAME = "turbo-frame##{Views::Integrations::HrisFieldPreviewFrame::FRAME_ID}".freeze
  TEAM = Hris::Field.new(id: "work.customColumns.column_team", name: "Team", kind: :list)

  setup do
    @tenant = FactoryBot.create(:tenant, :with_hibob_config)
    @admin_user = FactoryBot.create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      %w[hb-1 hb-2 hb-3 hb-4 hb-5].each do
        FactoryBot.create(:person, tenant: @tenant, hris_source: "hibob", external_id: it)
      end
    end
  end

  # Answers the preview's read, on the server thread too, so nothing reaches HiBob.
  def with_field(&)
    values = {
      "hb-1" => Hris::FieldValue.new(state: :value, id: "7", label: "Payments"),
      "hb-2" => Hris::FieldValue.new(state: :value, id: "7", label: "Payments"),
      "hb-3" => Hris::FieldValue.new(state: :value, id: "9", label: "Platform Reliability and Developer Experience"),
      "hb-4" => Hris::FieldValue.blank,
      "hb-5" => Hris::FieldValue.withheld
    }
    adapter = Object.new
    adapter.extend(Hris::FieldRows)
    adapter.define_singleton_method(:provider_name) { "hibob" }
    adapter.define_singleton_method(:catalogue_id) { |field_id| field_id }
    adapter.define_singleton_method(:field_catalogue) { [ TEAM ] }
    adapter.define_singleton_method(:read_field) { |_field_id, kind:, alongside: nil| values }
    Hris::BaseAdapter.stub(:for, adapter, &)
  end

  { "desktop" => DESKTOP_SIZE, "mobile" => MOBILE_SIZE }.each do |viewport, size|
    context "at #{viewport}" do
      setup do
        page.driver.browser.manage.window.resize_to(*size)
        sign_in_as(@admin_user)
      end

      should "show the units a field would make as a level" do
        with_field do
          visit tenant_hris_field_preview_path(field_id: TEAM.id, target: "level")
          assert_text "Preview an HRIS field"
          assert_selector FRAME, text: "Team as the level"
        end

        within(FRAME) do
          assert_equal [ "Payments 2 people", "Platform Reliability and Developer Experience 1 person" ],
                       all("li").map { it.text.squish }
          assert_text "Blank\n1"
        end
        assert_no_sideways_overflow
        screenshot("field_preview_level_#{viewport}")
      end

      should "count what a field would change as a fact" do
        with_field do
          visit tenant_hris_field_preview_path(field_id: TEAM.id, target: "cost_centre")
          assert_selector FRAME, text: "Team as the cost centre"
        end

        within(FRAME) do
          assert_text "Would change\n3"
          assert_no_selector "li"
        end
        assert_no_sideways_overflow
        screenshot("field_preview_fact_#{viewport}")
      end
    end
  end
end
