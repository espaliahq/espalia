# frozen_string_literal: true

require "test_helper"

# After a mid-cycle transfer the aggregate, the enrollment snapshot and
# `CurrentAssessment` must name the same home role: the new role before
# alignment starts, the one alignment started on after it
# (https://github.com/mr-yum/growth-os/issues/687). Driven through the real
# command handlers and subscriptions, so the sync handler runs too.
class PersonDevelopment::HomeRoleAgreementTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @fx = build_role_lens_framework(tenant: @tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant)
      @person = create(:person, tenant: @tenant, manager: @manager)
    end
    _assignment, @cycle_id = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant)
    @pd = PersonDevelopment::CommandHandler.new
  end

  def transfer_to_pm
    within_tenant do
      @pd.change_person_role(@person.id, @fx.framework_id, @fx.pm.role_id, @fx.pm_levels.fetch(2).level_id,
        reason: "transfer")
    end
  end

  # Role-less, so each side falls back on its own idea of home.
  def aggregate_starts_alignment
    within_tenant do
      PersonDevelopment::Repository.new.with_person_development(@person.id, @fx.framework_id) do |aggregate|
        aggregate.start_alignment(@cycle_id, started_by_id: @manager.id, cell_keys: [])
      end
    end
  end

  def aggregate_completes_alignment
    within_tenant do
      PersonDevelopment::Repository.new.with_person_development(@person.id, @fx.framework_id) do |aggregate|
        aggregate.complete_alignment(@cycle_id, completed_by_id: @manager.id)
      end
    end
  end

  def homes
    within_tenant do
      {
        snapshot: Assessments::RoleScope.home_role_ids(cycle_id: @cycle_id, framework_id: @fx.framework_id,
                                                       person_ids: [ @person.id ])[@person.id],
        projection: AssessmentCycleProgress.find_by!(cycle_id: @cycle_id, person_id: @person.id).home_role_id,
        alignment: AssessmentCycleRoleAlignment.for_participation(cycle_id: @cycle_id, person_id: @person.id)
                                               .find_by(home: true)&.role_id
      }
    end
  end

  def within_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  should "all move to the new role on a transfer before alignment" do
    transfer_to_pm
    aggregate_starts_alignment

    assert_equal({ snapshot: @fx.pm.role_id, projection: @fx.pm.role_id, alignment: @fx.pm.role_id }, homes)
  end

  should "all stay on the role alignment started on through a later transfer" do
    within_tenant { @pd.start_alignment(@person.id, @fx.framework_id, @cycle_id, started_by_id: @manager.id) }
    transfer_to_pm
    aggregate_completes_alignment

    role = @fx.engineer.role_id
    assert_equal({ snapshot: role, projection: role, alignment: role }, homes)
    assert_equal "aligned", within_tenant { AssessmentCycleProgress.find_by!(cycle_id: @cycle_id, person_id: @person.id).status }
  end
end
