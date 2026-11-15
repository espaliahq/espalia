# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::FundingTest < ActiveSupport::TestCase
  YEAR = { starts_on: "2027-01-01", ends_on: "2027-12-31", origin: "new" }.freeze

  setup do
    @tenant = create(:tenant)
    travel_to Time.utc(2026, 12, 1, 9)
    as_tenant do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      @outsider = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      @engineer = create(:framework_role, tenant: @tenant, name: "Software Engineer")
      @e2 = create(:framework_level, tenant: @tenant, role_id: @engineer.role_id, ordinal: 2, title: "Engineer II")
      @engineers = BudgetLine.create!(**YEAR, head_count: 3, role_id: @engineer.role_id)
      @platform = BudgetLine.create!(**YEAR, head_count: 1, cost_centre: "Platform")
    end
    @unit_id = SecureRandom.uuid_v7
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2027-01-01")[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
    @q1 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2027-03-31")[:scenario_id]
    @q2 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, parent_id: @q1, relation: "then", name: "Q2",
                                                       ends_on: "2027-06-30")[:scenario_id]
    @seat = call(Operations::TeamPlanning::SetPosition, plan_id: @plan_id, scenario_id: @q1, role_id: @engineer.role_id,
                                                        level_id: @e2.level_id, unit_id: @unit_id, fte: 0.5, basis: "new")[:position_id]
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def call(operation, as: @admin, **params)
    as_tenant { operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:) }
  end

  def funding(scenario_id = @q2, as: @admin) = call(Operations::TeamPlanning::Funding, as:, plan_id: @plan_id, scenario_id:)

  def set_funding(draws, scenario_id: @q1, position_id: @seat, as: @admin)
    call(Operations::TeamPlanning::SetPositionFunding, as:, plan_id: @plan_id, scenario_id:, position_id:, draws:)
  end

  def refusal(&) = assert_raises(Operations::Base::ParameterError, &).message

  should "give each position its derived line, each line its draws, and the totals, to a member" do
    read = funding(as: @viewer)

    assert_equal [ @plan_id, @q2, { starts_on: "2027-04-01", ends_on: "2027-06-30" } ], read.values_at(:plan_id, :scenario_id, :period)
    assert_equal({ position_id: @seat, unit_id: @unit_id, fte: "0.5", cost_centre: nil, cost_centre_source: "none", location: nil,
                   draw_reason: "open", starts_on: "2027-04-01", source: "derived", state: "funded", reason: nil, reason_text: nil,
                   draws: [ { budget_line_id: @engineers.id, share: "1", held: true } ], matching_ids: [ @engineers.id ] },
                 read[:positions].sole)
    assert_equal [ { budget_line_id: @engineers.id, positions: [ { position_id: @seat, share: "1", fte: "0.5", draw_reason: "open",
                                                                   starts_on: "2027-04-01" } ] } ], read[:budget_lines]
    assert_equal [ { positions: 1, fte: "0.5" }, { positions: 1, fte: "0.5" }, { positions: 0, fte: "0" } ],
                 read.values_at(:total, :funded, :unfunded)
  end

  should "refuse a non-member as an unknown plan, and the baseline" do
    assert_match(/No such plan/, refusal { funding(as: @outsider) })
    assert_match(/baseline has no period/, refusal { funding(@plan_id) })
  end

  should "set funding split across lines, reach the scenarios after, and go back to the derived line when cleared" do
    assert_equal({ plan_id: @plan_id, scenario_id: @q1, position_id: @seat,
                   draws: [ { budget_line_id: @platform.id, share: "0.5" }, { budget_line_id: @engineers.id, share: "0.5" } ] },
                 set_funding([ { budget_line_id: @platform.id.upcase, share: "0.5" }, { budget_line_id: @engineers.id, share: "0.5" } ]))

    position = funding[:positions].sole
    assert_equal [ "set", "funded", [ @platform.id, @engineers.id ] ], [ position[:source], position[:state], position[:draws].pluck(:budget_line_id) ]

    call(Operations::TeamPlanning::ClearChange, plan_id: @plan_id, scenario_id: @q1, subject_id: @seat, facet: "funding")
    assert_equal "derived", funding[:positions].sole[:source]
  end

  should "take a lone draw's share as the whole position" do
    assert_equal [ { budget_line_id: @platform.id, share: "1" } ], set_funding([ { budget_line_id: @platform.id } ])[:draws]
  end

  should "refuse shares that don't add up, a line named twice, and none at all" do
    assert_equal "The shares add up to 1",
                 refusal { set_funding([ { budget_line_id: @platform.id, share: "0.5" }, { budget_line_id: @engineers.id, share: "0.4" } ]) }
    assert_equal "Funding names each budget line once",
                 refusal { set_funding([ { budget_line_id: @platform.id, share: "0.5" }, { budget_line_id: @platform.id, share: "0.5" } ]) }
    assert_match(/share is a decimal above 0/, refusal { set_funding([ { budget_line_id: @platform.id, share: "0" }, { budget_line_id: @engineers.id, share: "1" } ]) })
    assert_match(/at least one|draws/, refusal { set_funding([]) })
  end

  should "refuse the baseline, a position that isn't open, a line the scenario doesn't hold or has cut, and a viewer" do
    draws = [ { budget_line_id: @platform.id } ]
    assert_equal Operations::TeamPlanning::BudgetLineWrite::BASELINE, refusal { set_funding(draws, scenario_id: @plan_id) }
    assert_equal "This scenario has no such open position", refusal { set_funding(draws, position_id: SecureRandom.uuid_v7) }
    assert_equal "This scenario has no such budget line", refusal { set_funding([ { budget_line_id: SecureRandom.uuid_v7 } ]) }

    call(Operations::TeamPlanning::CutBudgetLine, plan_id: @plan_id, scenario_id: @q1, budget_line_id: @platform.id)
    assert_equal "This scenario has cut that budget line", refusal { set_funding(draws) }
    assert_match(/No such plan/, refusal { set_funding([ { budget_line_id: @engineers.id } ], as: @viewer) })
  end

  should "flag a funding on a line the scenario later cuts as unfunded, and keep the change" do
    set_funding([ { budget_line_id: @platform.id } ])
    call(Operations::TeamPlanning::CutBudgetLine, plan_id: @plan_id, scenario_id: @q2, budget_line_id: @platform.id)

    position = funding[:positions].sole
    assert_equal [ "unfunded", "line_gone", [ false ] ], [ position[:state], position[:reason], position[:draws].pluck(:held) ]
    assert_empty funding[:budget_lines]
    assert_equal "set", funding(@q1)[:positions].sole[:source]
  end
end
