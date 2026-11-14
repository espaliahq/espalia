# frozen_string_literal: true

require "test_helper"
require_relative "../../support/rebuild_lock"

class OrgGraph::PersonDevelopmentCutoverTest < ActiveSupport::TestCase
  include RebuildLock

  HIBOB = { provider: "hibob", effective_on: "2026-02-01" }.freeze

  setup do
    @tenant = create(:tenant, :with_hibob_config, org_graph_people_projected_at: Time.current)
    @tenant.claim_hris_facts!
    @people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    as_tenant do
      @framework = create(:framework_state)
      role = create(:framework_role, code: "E", name: "Software Engineer")
      level = create(:framework_level, role_id: role.role_id, ordinal: 5, code: "E5", title: "Senior SWE")
      create(:framework_level, role_id: role.role_id, ordinal: 6, code: "E6", title: "Lead SWE")
      @lead = create(:person, tenant: @tenant, hris_source: "hibob", external_id: "hb-lead")
      @ada = create(:person, tenant: @tenant, hris_source: "hibob", external_id: "hb-ada")
      @people.record_person(@lead.id, **HIBOB, employment_status: "employed")
      @people.record_person(@ada.id, **HIBOB, employment_status: "employed", title: "Software Engineer", level: "5",
                                     manager_id: @lead.id)
      development = PersonDevelopment::CommandHandler.new
      development.assign_to_framework(@ada.id, @framework.framework_id, role.role_id, level.level_id)
      development.record_reporting_manager(@ada.id, @framework.framework_id, @lead.id)
    end
    @cutover = OrgGraph::PersonDevelopmentCutover.new(@tenant)
  end

  should "feed a tenant whose streams already agree" do
    assert_empty @cutover.run(apply: false).changes
    assert_not @tenant.reload.person_development_fed?

    assert @cutover.run(apply: true).applied
    assert @tenant.reload.person_development_fed?
  end

  should "refuse a tenant whose people are not cut over, or that is already fed" do
    @tenant.update!(org_graph_people_projected_at: nil)
    assert_raises(ArgumentError) { @cutover.run(apply: false) }

    @tenant.update!(org_graph_people_projected_at: Time.current, person_development_fed_at: Time.current)
    assert_raises(ArgumentError) { @cutover.run(apply: false) }
  end

  should "refuse while a projection the feed reads is rebuilt" do
    while_rebuilding(@tenant, AssessmentCycles::Projections::CurrentState) do
      assert_raises(ProjectionVersion::Rebuilding) { @cutover.run(apply: true) }
    end
    assert_not @tenant.reload.person_development_fed?
  end

  should "refuse when the Org Graph disagrees beyond a manager clear" do
    as_tenant { @people.change_level(@ada.id, "6", **HIBOB) }

    report = @cutover.run(apply: true)

    assert_equal({ change_level: [ @ada.id ] }, report.changes)
    assert_match "change_level", report.refusal
    assert_not @tenant.reload.person_development_fed?
  end

  context "with a manager the HRIS no longer names" do
    setup { as_tenant { @people.change_manager(@ada.id, nil, **HIBOB) } }

    should "count the clear and keep nothing until the operator confirms that count" do
      report = @cutover.run(apply: true)

      assert_equal({ clear_manager: [ @ada.id ] }, report.changes)
      assert_match "1 manager clears were counted, not 0", report.refusal
      assert_not @tenant.reload.person_development_fed?
      assert_equal @lead.id, manager_of(@ada)
    end

    should "clear it once the count is confirmed" do
      assert @cutover.run(apply: true, confirm_clears: 1).applied
      assert @tenant.reload.person_development_fed?
      assert_nil manager_of(@ada)
    end
  end

  should "hand the tenant back to the HRIS sync on revert" do
    @cutover.run(apply: true)
    @cutover.revert!

    assert_not @tenant.reload.person_development_fed?
  end

  private

  def manager_of(person)
    as_tenant { PersonDevelopment::CommandHandler.new.load(person.id, @framework.framework_id).manager_id }
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)
end
