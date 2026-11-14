# frozen_string_literal: true

require "test_helper"

class OrgGraph::PersonDevelopmentSweepJobTest < ActiveSupport::TestCase
  HIBOB = { provider: "hibob", effective_on: "2026-02-01" }.freeze

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    @tenant.claim_hris_facts!
    as_tenant do
      @framework = create(:framework_state)
      role = create(:framework_role, code: "E", name: "Software Engineer")
      @e5 = create(:framework_level, role_id: role.role_id, ordinal: 5, code: "E5", title: "Senior SWE")
      @e7 = create(:framework_level, role_id: role.role_id, ordinal: 7, code: "E7", title: "Staff SWE")
      @ada = create(:person, tenant: @tenant, hris_source: "hibob", external_id: "hb-ada")
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                              .record_person(@ada.id, **HIBOB, employment_status: "employed", title: "Software Engineer", level: "5")
    end
  end

  should "leave a tenant that is not fed alone" do
    assert_empty sweep
    assert_not held.assigned?
  end

  context "once the tenant is fed" do
    setup { @tenant.update!(person_development_fed_at: Time.current) }

    should "catch up everyone, then find nothing to do on a second run" do
      assert_equal({ assign: 1 }, sweep)
      assert_empty sweep
      assert_equal @e5.level_id, held.level_id
    end

    should "apply a title mapping edited since the last sync" do
      sweep
      @tenant.hris_config.role_mappings = [ HrisRoleMapping.new(hris_titles: [ "Software Engineer" ], framework_role_code: "E", level_ordinal: 7) ]
      @tenant.save!

      assert_equal({ change_level: 1 }, sweep)
      assert_equal @e7.level_id, held.level_id
    end
  end

  private

  def sweep = OrgGraph::PersonDevelopmentSweepJob.perform_now(@tenant.reload)

  def held = as_tenant { PersonDevelopment::CommandHandler.new.load(@ada.id, @framework.framework_id) }

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)
end
