# frozen_string_literal: true

require "test_helper"

# A step after a closed one stands on the Org Graph the day after the close,
# with what the closed steps planned and the Org Graph doesn't yet hold
# carried over ([#466](https://github.com/espaliahq/espalia/issues/466)).
class TeamPlanning::ClosedStepTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  CLOSED_ON = Time.utc(2026, 7, 2, 9)

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    @org = OrgGraph::CommandHandler.new(actor: SYSTEM)
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    departments = SecureRandom.uuid_v7
    @payments, @platform, @growth = Array.new(3) { SecureRandom.uuid_v7 }

    travel_to Time.utc(2025, 12, 15, 9)
    as_tenant do
      @engineer = create(:framework_role, code: "E", name: "Software Engineer")
      @e5 = create(:framework_level, role_id: @engineer.role_id, ordinal: 5, title: "Senior SWE")
      structure.define_taxonomy([ { level_id: departments, name: "Department" } ], effective_on: "2025-01-01")
      { @payments => "Payments", @platform => "Platform", @growth => "Growth" }.each do |id, name|
        structure.create_unit(id, name, level_id: departments, effective_on: "2025-01-01")
      end
      @ada, @brook = [ "Ada Quill", "Brook Tamsin" ].map do |name|
        create(:person, tenant: @tenant, name:).tap do
          @org.record_person(it.id, **ESPALIA, effective_on: "2025-12-01", employment_status: "employed", title: "Software Engineer",
                                               level: "5", fte: 1.0, country: "Mu", cost_centre: "Platform")
          @org.set_membership(it.id, @payments, **ESPALIA, effective_on: "2025-12-01", allocation: 1.0)
        end
      end

      ReferenceCurrency.create!(currency: "EUR")
      PayBand.create!(level: @e5, currency: "EUR", period: "year", minimum: 0, midpoint: 100_000, maximum: 200_000)
      BudgetLine.create!(starts_on: "2026-01-01", ends_on: "2026-12-31", origin: "new", amount: 150_000, currency: "EUR", period: "year",
                         cost_centre: "Platform", head_count: 2)
      @planner = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
    end

    @plan_id = new_plan(base_on: "2026-01-01")
    @h1 = fork(@plan_id, @plan_id, "H1", ends_on: "2026-06-30")
    @h2 = fork(@plan_id, @h1, "H2", ends_on: "2026-12-31")
    position(@plan_id, @h1)
    depart(@plan_id, @h1, @brook)
    place(@plan_id, @h1, @ada, @platform)
    position(@plan_id, @h2)

    on(Time.utc(2026, 6, 1, 9)) { @org.leave(@brook.id, **ESPALIA, effective_on: "2026-05-31") }
    travel_to CLOSED_ON
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def on(time, &) = travel_to(time) { as_tenant(&) }

  def context = AuthorizationContext.new(user: @planner.user, tenant_user: @planner, person: @planner.person)

  def handler = TeamPlanning::CommandHandler.new(actor: context)

  def new_plan(base_on:)
    SecureRandom.uuid_v7.tap do |plan_id|
      as_tenant do
        handler.create_plan(plan_id, name: "Next year", base_on:)
        handler.set_change(plan_id, TeamPlanning::Events::RuleSet, scenario_id: plan_id, subject_id: plan_id,
                                                                   end_state: { rule: "capacity_model", value: { families: {}, roles: { @engineer.role_id => { model: "per_fte" } } } })
      end
    end
  end

  def fork(plan_id, parent_id, name, **period)
    SecureRandom.uuid_v7.tap { |id| as_tenant { handler.fork_scenario(plan_id, id, parent_id:, relation: "then", name:, **period) } }
  end

  def position(plan_id, scenario_id)
    as_tenant do
      Operations::TeamPlanning::SetPosition.call(context:, params: { plan_id:, scenario_id:, role_id: @e5.role_id, level_id: @e5.level_id,
                                                                     unit_id: @payments, fte: 1, basis: "new", cost_centre: "Platform" })
    end
  end

  def depart(plan_id, scenario_id, person)
    as_tenant { handler.set_change(plan_id, TeamPlanning::Events::DepartureSet, scenario_id:, subject_id: person.id, end_state: { leaves_in_id: scenario_id }) }
  end

  def place(plan_id, scenario_id, person, unit_id)
    as_tenant do
      handler.set_change(plan_id, TeamPlanning::Events::AssignmentSet, scenario_id:, subject_id: person.id,
                                                                       end_state: { placements: [ { unit_id:, allocation: 1.0 } ] })
    end
  end

  def close(scenario_id = @h1) = as_tenant { handler.close_step(@plan_id, scenario_id) }

  def reopen(scenario_id = @h1) = as_tenant { handler.reopen_step(@plan_id, scenario_id) }

  # What a step prices and counts, by every read the timeline shows.
  def figures(plan_id, scenario_id)
    as_tenant do
      plan = TeamPlanningPlan.find(plan_id)
      map = TeamPlanning::Resolution.new(context:, plan:, scenario_id:).structure
      { people: map.people.map { [ it.id, it.memberships.map(&:unit_id) ] }.sort, outside: map.outside.map(&:id).sort,
        departed: map.departed.map(&:person_id), positions: map.positions.size, base_on: map.base_on,
        cost: TeamPlanning::Cost.new(context:, plan:, scenario_id:).call.parts.total,
        budget: (TeamPlanning::Budget.new(context:, plan:, scenario_id:).call.totals unless scenario_id == plan_id),
        capacity: TeamPlanning::Capacity.split(context:, plan:, scenario_id:).parts.total }
    end
  end

  def placed_in(scenario_id, person)
    as_tenant do
      TeamPlanning::Resolution.new(context:, plan: TeamPlanningPlan.find(@plan_id), scenario_id:).structure
                              .people.find { it.id == person.id }.memberships.map(&:unit_id)
    end
  end

  should "price and count a step after a closed one as a fresh first step from the day after, with what didn't happen carried over" do
    close

    fresh = new_plan(base_on: "2026-07-01")
    first = fork(fresh, fresh, "H2", ends_on: "2026-12-31")
    position(fresh, first)
    place(fresh, first, @ada, @platform)
    position(fresh, first)

    assert_equal figures(fresh, first), figures(@plan_id, @h2)
    assert_equal Date.new(2026, 7, 1), figures(@plan_id, @h2)[:base_on]
  end

  should "price a step after a closed one as a fresh first step when the Org Graph made a planned move happen" do
    on(Time.utc(2026, 6, 20, 9)) do
      @org.end_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-06-15")
      @org.set_membership(@ada.id, @platform, **ESPALIA, effective_on: "2026-06-15", allocation: 1.0)
    end
    close

    fresh = new_plan(base_on: "2026-07-01")
    first = fork(fresh, fresh, "H2", ends_on: "2026-12-31")
    2.times { position(fresh, first) }

    assert_equal figures(fresh, first), figures(@plan_id, @h2)
  end

  should "drop a change the Org Graph made happen, and carry over one it didn't" do
    close

    as_tenant do
      done = TeamPlanning::Resolution.new(context:, plan: TeamPlanningPlan.find(@plan_id), scenario_id: @h2).done_at_close(@h1, Date.new(2026, 6, 30))
      changes = TeamPlanning::Repository.new.load_plan(@plan_id).changes_in(@h1).to_h { [ it.data[:subject_id], it.event_id ] }
      assert_equal Set[changes.fetch(@brook.id)], done
    end
    assert_equal [ @platform ], placed_in(@h2, @ada)
  end

  should "carry over a change the Org Graph holds otherwise, so it still lands and still reads conflicting" do
    on(Time.utc(2026, 6, 20, 9)) do
      @org.end_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-06-15")
      @org.set_membership(@ada.id, @growth, **ESPALIA, effective_on: "2026-06-15", allocation: 1.0)
    end
    close

    assert_equal [ @platform ], placed_in(@h2, @ada)
    report = as_tenant { TeamPlanning::Status.new(context:, plan: TeamPlanningPlan.find(@plan_id), scenario_id: @h2).call }
    assert_equal :conflicting, report.statuses.find { it.subject_id == @ada.id }.status
  end

  should "restore every figure exactly once the step reopens" do
    before = [ figures(@plan_id, @h1), figures(@plan_id, @h2) ]
    close
    assert_not_equal before.last, figures(@plan_id, @h2)

    reopen

    assert_equal before, [ figures(@plan_id, @h1), figures(@plan_id, @h2) ]
  end

  should "leave the closed step, and the root, on the plan's own baseline" do
    before = [ figures(@plan_id, @plan_id), figures(@plan_id, @h1) ]
    close

    assert_equal before, [ figures(@plan_id, @plan_id), figures(@plan_id, @h1) ]
  end
end
