# frozen_string_literal: true

require "application_system_test_case"

# The publish-review page says what the version changes (#497). A draft that
# only took a capability off a role used to read "nothing to migrate" under a
# warning that publishing cannot be undone.
class Frameworks::PublicationReviewChangesSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      family = SecureRandom.uuid_v7
      ae = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      @binding_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, family, "Data")
      handler.add_role(@framework_id, ae, family, "Analytics Engineer", "AE", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, ae, 1, "Analytics Engineer I", "AE1", is_entry: true)
      handler.add_capability_category(@framework_id, cat_id, "Engineering", ordinal: 1)
      handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "System Design")
      handler.create_capability_role_binding(@framework_id, @binding_id, cap_id, ae)
      handler.publish_version(@framework_id, "test") # v1

      cycle = FactoryBot.create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id)
      2.times { FactoryBot.create(:assessment_cycle_enrollment, tenant: @tenant, cycle: cycle, role_id: ae) }

      handler.remove_capability_role_binding(@framework_id, @binding_id) # opens v2
    end
  end

  [ [ "desktop", DESKTOP_SIZE ], [ "mobile", MOBILE_SIZE ] ].each do |label, size|
    should "list a removed role and the assessments it reaches (#{label})" do
      page.driver.browser.manage.window.resize_to(*size)
      sign_in_as(@admin_user)
      visit new_framework_publication_path(@framework_id)

      assert_text "What changes in v2"
      within "[data-draft-change='roles_removed']" do
        assert_text "Removed from a role (1)"
        assert_text "System Design from Analytics Engineer — 2 people in the open cycle"
        assert_text "Ratings already made on these are kept"
      end
      assert_no_text "nothing to migrate"
      assert_button "Confirm & publish v2"
      assert_equal page.evaluate_script("document.documentElement.clientWidth"),
                   page.evaluate_script("document.documentElement.scrollWidth")
    end
  end
end
