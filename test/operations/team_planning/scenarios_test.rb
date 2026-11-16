# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::ScenariosTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @other_admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2027-01-01")[:plan_id]
  end

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person)
      operation.call(context: context, params: params)
    end
  end

  def fork(**params) = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, **params)

  def set(kind, subject_id, scenario_id: @q1, **end_state)
    ActsAsTenant.with_tenant(@tenant) do
      TeamPlanning::CommandHandler.new(actor: AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin.person))
        .set_change(@plan_id, kind, scenario_id:, subject_id:, end_state:)
      TeamPlanningOverride.find_by!(scenario_id:, subject_id:).event_id
    end
  end

  def described_count = Rails.configuration.event_store.read.of_type([ TeamPlanning::Events::ScenarioDescribed ]).count

  def refusal(operation, as: @admin, **params)
    assert_raises(Operations::Base::ParameterError) { call(operation, as:, plan_id: @plan_id, **params) }.message
  end

  context "ForkScenario" do
    should "fork a step after the baseline by default, and an alternative to it" do
      q1 = fork(relation: "then", name: "Q1", ends_on: "2027-03-31")
      assert_equal({ plan_id: @plan_id, scenario_id: q1[:scenario_id], parent_id: @plan_id, relation: "then", name: "Q1",
                     starts_on: "2027-01-01", ends_on: "2027-03-31" }, q1)

      lean = fork(parent_id: q1[:scenario_id].upcase, relation: "instead", name: "Lean Q1")
      assert_equal [ q1[:scenario_id], "2027-01-01", "2027-03-31" ], lean.values_at(:parent_id, :starts_on, :ends_on)
    end

    should "start a first step on a later day, and refuse one before the base date" do
      assert_equal "A first step starts on or after the plan's base date, 2027-01-01",
                   refusal(Operations::TeamPlanning::ForkScenario, relation: "then", name: "Q1", starts_on: "2026-12-31", ends_on: "2027-03-31")
      assert_equal %w[2027-01-14 2027-03-31],
                   fork(relation: "then", name: "Q1", starts_on: "2027-01-14", ends_on: "2027-03-31").values_at(:starts_on, :ends_on)
    end

    should "fork a step with no end date, and ask when the step after it starts" do
      q1 = fork(relation: "then", name: "Q1")
      assert_equal [ "2027-01-01", nil ], q1.values_at(:starts_on, :ends_on)

      assert_equal "Its parent has no end date: say when the new step starts",
                   refusal(Operations::TeamPlanning::ForkScenario, parent_id: q1[:scenario_id], relation: "then", name: "Q2")
      q2 = fork(parent_id: q1[:scenario_id], relation: "then", name: "Q2", starts_on: "2027-04-01")
      assert_equal [ "2027-04-01", nil ], q2.values_at(:starts_on, :ends_on)
      assert_equal [ nil, "2027-03-31", nil ], call(Operations::TeamPlanning::Scenarios, plan_id: @plan_id)[:scenarios].pluck(:ends_on)
    end

    should "pass on the plan's refusals and refuse bad ids and dates" do
      assert_equal "parent_id must be a UUID, got \"q1\"",
                   refusal(Operations::TeamPlanning::ForkScenario, parent_id: "q1", relation: "instead", name: "Q1")
      assert_equal "ends_on must be a date, YYYY-MM-DD",
                   refusal(Operations::TeamPlanning::ForkScenario, relation: "then", name: "Q1", ends_on: "March")
    end
  end

  context "with a step and its alternative" do
    setup do
      @q1 = fork(relation: "then", name: "Q1", ends_on: "2027-03-31")[:scenario_id]
      @lean = fork(parent_id: @q1, relation: "instead", name: "Lean Q1")[:scenario_id]
    end

    should "list the baseline first, then each scenario with its parent, relation and period" do
      call(Operations::TeamPlanning::SetScenarioPeriod, plan_id: @plan_id, scenario_id: @q1, ends_on: "2027-02-28")

      assert_equal({ plan_id: @plan_id, scenarios: [
        { scenario_id: @plan_id, parent_id: nil, relation: nil, name: "Baseline", description: nil, starts_on: "2027-01-01", ends_on: nil },
        { scenario_id: @q1, parent_id: @plan_id, relation: "then", name: "Q1", description: nil, starts_on: "2027-01-01", ends_on: "2027-02-28" },
        { scenario_id: @lean, parent_id: @q1, relation: "instead", name: "Lean Q1", description: nil, starts_on: "2027-01-01", ends_on: "2027-02-28" }
      ] }, call(Operations::TeamPlanning::Scenarios, plan_id: @plan_id))
    end

    should "move a step's end and say the period it now has" do
      assert_equal({ plan_id: @plan_id, scenario_id: @q1, starts_on: "2027-01-01", ends_on: "2027-04-30" },
                   call(Operations::TeamPlanning::SetScenarioPeriod, plan_id: @plan_id, scenario_id: @q1, ends_on: "2027-04-30"))
      assert_equal "This scenario is an alternative: it takes its period from its parent",
                   refusal(Operations::TeamPlanning::SetScenarioPeriod, scenario_id: @lean, ends_on: "2027-04-30")
    end

    should "take an empty end as no end date, only on the last step on a line" do
      preview = call(Operations::TeamPlanning::PeriodPreview, plan_id: @plan_id, scenario_id: @q1, ends_on: "")
      assert_equal [ nil, "2027-03-31", [ [ @lean, nil, "2027-03-31" ] ] ],
                   [ preview[:ends_on], preview[:previous_ends_on], preview[:moves].map { it.values_at(:scenario_id, :ends_on, :previous_ends_on) } ]
      assert_equal({ plan_id: @plan_id, scenario_id: @q1, starts_on: "2027-01-01", ends_on: nil },
                   call(Operations::TeamPlanning::SetScenarioPeriod, plan_id: @plan_id, scenario_id: @q1, ends_on: ""))

      fork(parent_id: @q1, relation: "then", name: "Q2", starts_on: "2027-04-01")
      assert_equal "Only the last step on a line can have no end date: a step comes after this one",
                   refusal(Operations::TeamPlanning::SetScenarioPeriod, scenario_id: @q1, ends_on: "")
      assert_equal "ends_on must be a date, YYYY-MM-DD", refusal(Operations::TeamPlanning::SetScenarioPeriod, scenario_id: @q1, ends_on: "soon")
    end

    should "start a first step after the base date, preview and move that start, and refuse one for a later step" do
      q2 = fork(parent_id: @q1, relation: "then", name: "Q2", ends_on: "2027-06-30")[:scenario_id]

      preview = call(Operations::TeamPlanning::PeriodPreview, plan_id: @plan_id, scenario_id: @q1, starts_on: "2027-01-14", ends_on: "2027-03-31")
      assert_equal [ "2027-01-14", "2027-01-01", [ @lean ] ], [ preview[:starts_on], preview[:previous_starts_on], preview[:moves].pluck(:scenario_id) ]

      assert_equal({ plan_id: @plan_id, scenario_id: @q1, starts_on: "2027-01-14", ends_on: "2027-03-31" },
                   call(Operations::TeamPlanning::SetScenarioPeriod, plan_id: @plan_id, scenario_id: @q1, starts_on: "2027-01-14", ends_on: "2027-03-31"))
      assert_equal "Its start follows the step before it: change that step's end",
                   refusal(Operations::TeamPlanning::SetScenarioPeriod, scenario_id: q2, starts_on: "2027-04-02", ends_on: "2027-06-30")
      assert_equal "A first step starts on or after the plan's base date, 2027-01-01",
                   refusal(Operations::TeamPlanning::PeriodPreview, scenario_id: @q1, starts_on: "2026-12-31", ends_on: "2027-03-31")
    end

    should "preview what moving a step's end would move, and move nothing" do
      q2 = fork(parent_id: @q1, relation: "then", name: "Q2", ends_on: "2027-06-30")[:scenario_id]

      assert_equal({ plan_id: @plan_id, scenario_id: @q1, starts_on: "2027-01-01", ends_on: "2027-02-28",
                     previous_starts_on: "2027-01-01", previous_ends_on: "2027-03-31",
                     moves: [
                       { scenario_id: @lean, starts_on: "2027-01-01", ends_on: "2027-02-28", previous_starts_on: "2027-01-01", previous_ends_on: "2027-03-31" },
                       { scenario_id: q2, starts_on: "2027-03-01", ends_on: "2027-06-30", previous_starts_on: "2027-04-01", previous_ends_on: "2027-06-30" }
                     ] },
                   call(Operations::TeamPlanning::PeriodPreview, plan_id: @plan_id, scenario_id: @q1, ends_on: "2027-02-28"))
      assert_equal "2027-03-31", call(Operations::TeamPlanning::Scenarios, plan_id: @plan_id)[:scenarios].second[:ends_on]
      assert_equal "Q2 would end on 2027-06-30, before it starts on 2027-07-01",
                   refusal(Operations::TeamPlanning::PeriodPreview, scenario_id: @q1, ends_on: "2027-06-30")
      assert_equal "This scenario is an alternative: it takes its period from its parent",
                   refusal(Operations::TeamPlanning::PeriodPreview, scenario_id: @lean, ends_on: "2027-04-30")
    end

    should "rename a scenario, and refuse the baseline" do
      assert_equal({ plan_id: @plan_id, scenario_id: @q1, name: "First quarter" },
                   call(Operations::TeamPlanning::RenameScenario, plan_id: @plan_id, scenario_id: @q1, name: " First quarter "))
      assert_equal "First quarter", call(Operations::TeamPlanning::Scenarios, plan_id: @plan_id)[:scenarios].second[:name]
      assert_equal "The baseline can't be renamed", refusal(Operations::TeamPlanning::RenameScenario, scenario_id: @plan_id, name: "Now")
      assert_equal "name can't be blank", refusal(Operations::TeamPlanning::RenameScenario, scenario_id: @q1, name: "")
    end

    should "describe a scenario, writing nothing for the same text, and refuse the baseline" do
      describe = ->(text) { call(Operations::TeamPlanning::DescribeScenario, plan_id: @plan_id, scenario_id: @q1, description: text) }
      assert_equal({ plan_id: @plan_id, scenario_id: @q1, description: "Hire two seniors" }, describe.(" Hire two seniors "))
      assert_equal "Hire two seniors", call(Operations::TeamPlanning::Scenarios, plan_id: @plan_id)[:scenarios].second[:description]

      assert_no_difference -> { described_count } do
        describe.("Hire two seniors")
      end
      assert_equal({ plan_id: @plan_id, scenario_id: @q1, description: nil }, describe.(""))
      assert_nil call(Operations::TeamPlanning::Scenarios, plan_id: @plan_id)[:scenarios].second[:description]
      assert_equal "The baseline can't be described",
                   refusal(Operations::TeamPlanning::DescribeScenario, scenario_id: @plan_id, description: "Now")
    end

    should "write rather than guess while a rebuild holds the scenarios" do
      call(Operations::TeamPlanning::DescribeScenario, plan_id: @plan_id, scenario_id: @q1, description: "Hire two seniors")
      ProjectionVersion.stub(:unless_rebuilding, ->(*) { raise ProjectionVersion::Rebuilding, "busy" }) do
        assert_difference -> { described_count } do
          call(Operations::TeamPlanning::DescribeScenario, plan_id: @plan_id, scenario_id: @q1, description: "Hire two seniors")
        end
      end
    end

    should "remove a leaf, and refuse a scenario others fork from" do
      assert_equal "1 scenario forks from this one: remove it first",
                   refusal(Operations::TeamPlanning::RemoveScenario, scenario_id: @q1)
      assert_equal({ plan_id: @plan_id, scenario_id: @lean, removed: true },
                   call(Operations::TeamPlanning::RemoveScenario, plan_id: @plan_id, scenario_id: @lean))
      assert_equal [ @plan_id, @q1 ], call(Operations::TeamPlanning::Scenarios, plan_id: @plan_id)[:scenarios].pluck(:scenario_id)
    end

    should "split a scenario, list the agreed part in its place with the rest on it, and refuse a bad split" do
      moving = set(TeamPlanning::Events::LevelSet, @admin.person_id, level: "4")
      set(TeamPlanning::Events::LevelSet, @other_admin.person_id, level: "5")

      split = call(Operations::TeamPlanning::SplitScenario, plan_id: @plan_id, scenario_id: @q1, event_ids: [ moving.upcase ], name: " Agreed  Q1 ")

      assert_equal({ plan_id: @plan_id, scenario_id: @q1, agreed_id: split[:agreed_id], name: "Agreed Q1", moved_event_ids: [ moving ] }, split)
      listed = call(Operations::TeamPlanning::Scenarios, plan_id: @plan_id)[:scenarios].index_by { it[:scenario_id] }
      assert_equal [ @plan_id, "then", "2027-03-31" ], listed[split[:agreed_id]].values_at(:parent_id, :relation, :ends_on)
      assert_equal [ split[:agreed_id], "on" ], listed[@q1].values_at(:parent_id, :relation)
      assert_equal "Every change would move: approve the scenario whole instead",
                   refusal(Operations::TeamPlanning::SplitScenario, scenario_id: split[:agreed_id], event_ids: [ moving ], name: "Again")
      assert_equal "event_ids must hold event ids, got \"lin\"",
                   refusal(Operations::TeamPlanning::SplitScenario, scenario_id: @q1, event_ids: [ "lin" ], name: "Again")
    end

    should "name the event id of each change a moving one needs, so the caller can move it across too" do
      unit_id = SecureRandom.uuid_v7
      creates = set(TeamPlanning::Events::UnitSet, unit_id, name: "Payments", parent_id: nil, level_id: SecureRandom.uuid_v7)
      placed = set(TeamPlanning::Events::AssignmentSet, @admin.person_id, placements: [ { unit_id:, allocation: 1.0 } ])
      set(TeamPlanning::Events::LevelSet, @other_admin.person_id, level: "5")

      assert_equal "The agreed part can't stand without a change that stays: unit of #{unit_id}. Move it across too (event_ids #{creates})",
                   refusal(Operations::TeamPlanning::SplitScenario, scenario_id: @q1, event_ids: [ placed ], name: "Agreed")
    end

    should "read as missing to an admin outside the plan" do
      [ [ Operations::TeamPlanning::Scenarios, {} ],
        [ Operations::TeamPlanning::ForkScenario, { parent_id: @q1, relation: "instead", name: "Mine" } ],
        [ Operations::TeamPlanning::RenameScenario, { scenario_id: @q1, name: "Mine" } ],
        [ Operations::TeamPlanning::DescribeScenario, { scenario_id: @q1, description: "Mine" } ],
        [ Operations::TeamPlanning::SetScenarioPeriod, { scenario_id: @q1, ends_on: "2027-04-30" } ],
        [ Operations::TeamPlanning::PeriodPreview, { scenario_id: @q1, ends_on: "2027-04-30" } ],
        [ Operations::TeamPlanning::RemoveScenario, { scenario_id: @lean } ] ].each do |operation, params|
        assert_equal "No such plan", refusal(operation, as: @other_admin, **params), operation.name
      end
    end
  end
end
