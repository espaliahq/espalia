# frozen_string_literal: true

require "test_helper"

# A closed step's plan beside what the Org Graph held on its last day
# ([#466](https://github.com/espaliahq/espalia/issues/466)).
class TeamPlanning::StepOutcomeTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM

  setup do
    @tenant = create(:tenant, :with_hibob_config)
    @org = OrgGraph::CommandHandler.new(actor: SYSTEM)
    @structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    departments = SecureRandom.uuid_v7
    @payments, @platform, @growth, @labs = Array.new(4) { SecureRandom.uuid_v7 }

    travel_to Time.utc(2025, 12, 15, 9)
    as_tenant do
      @engineer = create(:framework_role, code: "E", name: "Software Engineer")
      @e5 = create(:framework_level, role_id: @engineer.role_id, ordinal: 5, title: "Senior SWE")
      @structure.define_taxonomy([ { level_id: departments, name: "Department" } ], effective_on: "2025-01-01")
      { @payments => "Payments", @platform => "Platform", @growth => "Growth", @labs => "Labs" }.each do |id, name|
        @structure.create_unit(id, name, level_id: departments, effective_on: "2025-01-01")
      end
      @ada, @brook, @cara, @dee, @eve = %w[Ada Brook Cara Dee Eve].map { person(it, @payments) }
      @gus = person("Gus", @labs)
      @planner = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
    end

    @plan_id = SecureRandom.uuid_v7
    as_tenant do
      handler.create_plan(@plan_id, name: "Next year", base_on: "2026-01-01")
      handler.set_plan_scope(@plan_id, unit_ids: [ @payments, @platform, @labs ])
    end
    @h1 = fork(@plan_id, "H1", ends_on: "2026-06-30")
    @h2 = fork(@h1, "H2", ends_on: "2026-12-31")
    place(@ada, unit_id: @platform)
    place(@cara, unit_id: @platform)
    @seat = position
    place(@eve, position_id: @seat)
    @open_seat = position
    @hire = SecureRandom.uuid_v7
    as_tenant { handler.set_change(@plan_id, TeamPlanning::Events::PlaceholderSet, scenario_id: @h1, subject_id: @hire, end_state: { label: "Data hire" }) }
    place(@hire, position_id: @open_seat, id: true)

    on(Time.utc(2026, 6, 20, 9)) do
      move(@ada, @payments, @platform)
      move(@brook, @payments, @growth)
      move(@eve, @payments, @platform)
      @org.leave(@dee.id, **ESPALIA, effective_on: "2026-05-31")
      @fay = person("Fay", @platform, on: "2026-06-01")
      @structure.rename_unit(@platform, "Platform Core", effective_on: "2026-06-01")
    end
    travel_to Time.utc(2026, 7, 2, 9)
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def on(time, &) = travel_to(time) { as_tenant(&) }

  def context = AuthorizationContext.new(user: @planner.user, tenant_user: @planner, person: @planner.person)

  def handler = TeamPlanning::CommandHandler.new(actor: context)

  def person(name, unit_id, on: "2025-12-01")
    create(:person, tenant: @tenant, name:).tap do
      @org.record_person(it.id, **ESPALIA, effective_on: on, employment_status: "employed", title: "Software Engineer", level: "5", fte: 1.0)
      @org.set_membership(it.id, unit_id, **ESPALIA, effective_on: on, allocation: 1.0)
    end
  end

  def move(person, from, to)
    @org.end_membership(person.id, from, **ESPALIA, effective_on: "2026-06-15")
    @org.set_membership(person.id, to, **ESPALIA, effective_on: "2026-06-15", allocation: 1.0)
  end

  def fork(parent_id, name, **period)
    SecureRandom.uuid_v7.tap { |id| as_tenant { handler.fork_scenario(@plan_id, id, parent_id:, relation: "then", name:, **period) } }
  end

  def position
    as_tenant do
      Operations::TeamPlanning::SetPosition.call(context:, params: { plan_id: @plan_id, scenario_id: @h1, role_id: @e5.role_id, level_id: @e5.level_id,
                                                                     unit_id: @platform, fte: 1, basis: "new" })[:position_id]
    end
  end

  def place(subject, id: false, **place)
    as_tenant do
      handler.set_change(@plan_id, TeamPlanning::Events::AssignmentSet, scenario_id: @h1, subject_id: id ? subject : subject.id,
                                                                        end_state: { placements: [ { **place, allocation: 1.0 } ] })
    end
  end

  def close = as_tenant { handler.close_step(@plan_id, @h1) }

  def outcome(scenario_id = @h1) = as_tenant { TeamPlanning::StepOutcome.new(context:, plan: TeamPlanningPlan.find(@plan_id), scenario_id:).call }

  def row(result, unit_id) = result.units.find { it.unit_id == unit_id }

  def people(result, unit_id) = row(result, unit_id).people.to_h { [ result.names.fetch(it.person_id), it.outcome ] }

  context "a closed step" do
    setup { close }

    should "read each planned move as it went, by unit, on the step's last day" do
      result = outcome

      assert_equal Date.new(2026, 6, 30), result.ends_on
      assert_nil result.known_on
      assert_equal({ "Ada" => "as_planned", "Cara" => "planned_not_here", "Eve" => "as_planned", "Data hire" => "hire_not_filled",
                     "Fay" => "here_not_planned" }, people(result, @platform))
      assert_equal({ "Brook" => "planned_not_here", "Dee" => "planned_not_here", "Cara" => "here_not_planned" }, people(result, @payments))
      assert_equal [ 4.0, 3.0 ], [ row(result, @platform).planned_heads, row(result, @platform).actual_heads ]
    end

    should "fill a seat only through the plan's own link, never from someone new in the unit" do
      seats = row(outcome, @platform).seats.to_h { [ it.position_id, it ] }

      assert_equal @eve.id, seats.fetch(@seat).filled_by_id
      assert_nil seats.fetch(@open_seat).filled_by_id, "Fay joined Platform, but the plan never placed her in the seat"
      assert_equal @hire, seats.fetch(@open_seat).hire_id
    end

    should "say nothing of where someone outside the plan's scope went, or that they left" do
      result = outcome

      assert_not result.units.any? { it.unit_id == @growth }
      assert_not result.names.value?("Growth")
      assert_equal %w[Brook Dee], row(result, @payments).people.select { it.outcome == "planned_not_here" }.map { result.names[it.person_id] }.sort
    end

    should "key each row on its unit id under the plan's name, renamed or retired since" do
      on(Time.utc(2026, 6, 25, 9)) do
        @org.end_membership(@gus.id, @labs, **ESPALIA, effective_on: "2026-06-01")
        @structure.retire_unit(@labs, effective_on: "2026-06-02")
      end
      result = outcome

      assert_equal "Platform", row(result, @platform).name
      assert_equal "Labs", row(result, @labs).name
      assert_equal [ 1.0, 0.0 ], [ row(result, @labs).planned_heads, row(result, @labs).actual_heads ]
      assert_equal({ "Gus" => "planned_not_here" }, people(result, @labs))
    end

    should "read an archived plan as the Org Graph knew it on the archive day" do
      as_tenant { handler.archive_plan(@plan_id) }
      on(Time.utc(2026, 7, 10, 9)) { move(@cara, @payments, @platform) }

      result = outcome
      assert_equal Date.new(2026, 7, 2), result.known_on
      assert_equal "planned_not_here", people(result, @platform).fetch("Cara")
    end
  end

  should "refuse an open step, and a step reopened" do
    assert_raises(TeamPlanning::Error, match: TeamPlanning::StepOutcome::NOT_CLOSED) { outcome }

    close
    as_tenant { handler.reopen_step(@plan_id, @h1) }
    assert_raises(TeamPlanning::Error, match: TeamPlanning::StepOutcome::NOT_CLOSED) { outcome }
    assert_raises(TeamPlanning::Error, match: TeamPlanning::StepOutcome::NOT_CLOSED) { outcome(@h2) }
  end
end
