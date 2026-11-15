# frozen_string_literal: true

require "test_helper"

class TeamPlanning::CommandHandlerSplitTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM

  setup do
    @tenant = create(:tenant)
    org = OrgGraph::CommandHandler.new(actor: SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    @squads = SecureRandom.uuid_v7
    @payments = SecureRandom.uuid_v7

    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      @brook = create(:person, tenant: @tenant, name: "Brook Tamsin")
      structure.define_taxonomy([ { level_id: @squads, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: @squads, effective_on: "2026-01-01")
      [ @ada, @brook ].each do
        org.record_person(it.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", title: "Engineer")
        org.set_membership(it.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0)
      end

      @planner = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @plan_id = SecureRandom.uuid_v7
      handler.create_plan(@plan_id, name: "Next year", base_on: Date.new(2026, 3, 2))
      @q1 = SecureRandom.uuid_v7
      handler.fork_scenario(@plan_id, @q1, parent_id: @plan_id, relation: "then", name: "Q1", ends_on: "2026-06-30")
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def context_for(tenant_user) = AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: tenant_user.person)

  def handler(as = @planner) = TeamPlanning::CommandHandler.new(actor: context_for(as))

  def plan(kind, subject_id, **end_state)
    as_tenant { handler.set_change(@plan_id, kind, scenario_id: @q1, subject_id:, end_state:) }
    TeamPlanningOverride.find_by!(scenario_id: @q1, subject_id:).event_id
  end

  def place(person, unit_id) = plan(TeamPlanning::Events::AssignmentSet, person.id, placements: [ { unit_id:, allocation: 1.0 } ])

  def split(*event_ids, as: @planner)
    SecureRandom.uuid_v7.tap { |agreed_id| as_tenant { handler(as).split_scenario(@plan_id, @q1, agreed_id:, name: "Agreed", event_ids:) } }
  end

  should "let a change move when the baseline holds what it needs, even if the rest edits it, and block one that needs a unit the rest creates" do
    platform = SecureRandom.uuid_v7
    creates = plan(TeamPlanning::Events::UnitSet, platform, name: "Platform", parent_id: nil, level_id: @squads)
    to_platform = place(@brook, platform)
    to_payments = place(@ada, @payments)
    plan(TeamPlanning::Events::UnitSet, @payments, name: "Payments and Billing", parent_id: nil, level_id: @squads)

    error = assert_raises(TeamPlanning::SplitBlocked) { split(to_platform) }
    assert_equal [ [ creates, to_platform ] ], error.blocks.map { [ it.event_id, it.blocks_event_id ] }

    agreed = split(to_payments)
    assert_equal [ to_payments ], TeamPlanningOverride.where(scenario_id: agreed).pluck(:event_id)
  end

  should "read as missing to someone who can't edit the plan" do
    moving = place(@ada, @payments)
    place(@brook, @payments)
    outsider = create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant))

    assert_equal "No such plan", assert_raises(TeamPlanning::Error) { split(moving, as: outsider) }.message
  end
end
