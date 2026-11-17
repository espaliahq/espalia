# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::StepOutcomeTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      @holder = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      @outsider = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @unit_id = SecureRandom.uuid_v7
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      structure.define_taxonomy([ { level_id: (level_id = SecureRandom.uuid_v7), name: "Department" } ], effective_on: "2026-01-01")
      structure.create_unit(@unit_id, "Payments", level_id:, effective_on: "2026-01-01")
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).tap do |org|
        org.record_person(@viewer.person_id, provider: "espalia", effective_on: "2026-01-01", employment_status: "employed")
        org.set_membership(@viewer.person_id, @unit_id, provider: "espalia", effective_on: "2026-01-01", allocation: 1.0)
      end
    end
    @plan_id = call(:CreatePlan, name: "Next year", base_on: "2026-03-02")[:plan_id]
    call(:AddPlanMember, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
    @q1 = call(:ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2026-06-30")[:scenario_id]
    travel_to Time.utc(2026, 7, 1, 9)
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def call(operation, as: @holder, **params)
    context = AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person)
    as_tenant { "Operations::TeamPlanning::#{operation}".constantize.call(context:, params:) }
  end

  def outcome(scenario_id = @q1, as: @viewer) = call(:StepOutcome, as:, plan_id: @plan_id, scenario_id:)

  def refusal(&) = assert_raises(Operations::Base::ParameterError, &).message

  should "give a viewer each unit's heads and people on the step's last day, by unit id" do
    call(:CloseStep, plan_id: @plan_id, scenario_id: @q1)

    assert_equal({ plan_id: @plan_id, scenario_id: @q1, ends_on: "2026-06-30", known_on: nil,
                   units: [ { unit_id: @unit_id, name: "Payments", planned_heads: 1.0, actual_heads: 1.0,
                              people: [ { person_id: @viewer.person_id, name: @viewer.person.name, outcome: "as_planned" } ], seats: [] } ] },
                 outcome)
  end

  should "refuse an open step, an unknown scenario and anyone outside the plan" do
    assert_equal TeamPlanning::StepOutcome::NOT_CLOSED, refusal { outcome }
    assert_equal "This plan has no such scenario", refusal { outcome(SecureRandom.uuid_v7) }

    call(:CloseStep, plan_id: @plan_id, scenario_id: @q1)
    assert_equal "No such plan", refusal { outcome(as: @outsider) }
  end
end
