# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::SettleConflictTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  BASE_ON = Date.new(2026, 3, 2)

  setup do
    @tenant = create(:tenant)
    @org = OrgGraph::CommandHandler.new(actor: SYSTEM)

    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      @brook = create(:person, tenant: @tenant, name: "Brook Tamsin")
      @org.record_person(@brook.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", level: "3")

      @editor = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @viewer = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @plan_id = SecureRandom.uuid_v7
      handler.create_plan(@plan_id, name: "Next year", base_on: BASE_ON)
      handler.add_member(@plan_id, @viewer.person_id, role: "viewer")
      @q1 = fork("Q1", parent_id: @plan_id, relation: "then", ends_on: "2026-06-30")
      @lean = fork("Lean Q1", parent_id: @q1, relation: "instead")
      @bold = fork("Bold Q1", parent_id: @q1, relation: "instead")
    end

    call(:SetPlannedLevel, plan_id: @plan_id, scenario_id: @q1, person_id: @brook.id, level: "4", note: "Promised in March")
    travel_to(Time.utc(2026, 3, 20, 9)) { as_tenant { @org.change_level(@brook.id, "5", **ESPALIA, effective_on: "2026-03-20") } }
    travel_to Time.utc(2026, 3, 25, 9)
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def context_for(account) = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)

  def handler = TeamPlanning::CommandHandler.new(actor: context_for(@editor))

  def fork(name, parent_id:, relation:, **period)
    SecureRandom.uuid_v7.tap { handler.fork_scenario(@plan_id, it, parent_id:, relation:, name:, **period) }
  end

  def call(operation, as: @editor, **params)
    as_tenant { "Operations::TeamPlanning::#{operation}".constantize.call(context: context_for(as), params:) }
  end

  def rebase = call(:RebasePlan, plan_id: @plan_id, base_on: BASE_ON.iso8601)

  def settle(scenario_id, choice, as: @editor, facet: "level", **params)
    call(:SettleConflict, as:, plan_id: @plan_id, scenario_id:, subject_id: @brook.id, facet:, choice:, **params)
  end

  def brook(scenario_id) = call(:Status, plan_id: @plan_id, scenario_id:)[:statuses].find { it[:subject_id] == @brook.id }

  def last_entry(scenario_id) = call(:History, plan_id: @plan_id, scenario_id:)[:entries].last

  def map(scenario_id) = call(:ScenarioMap, plan_id: @plan_id, scenario_id:).to_json

  def departure_override(scenario_id)
    call(:Overrides, plan_id: @plan_id, scenario_id:)[:overrides].find { it[:subject_id] == @brook.id && it[:facet] == "departure" }
  end

  def refusal(&) = assert_raises(Operations::Base::ParameterError, &).message

  def settle_pay(as:)
    as_tenant do
      TeamPlanning::CommandHandler.new(actor: context_for(as))
                                  .settle_conflict(@plan_id, scenario_id: @q1, subject_id: @brook.id, facet: "data:pay", choice: "plan")
    end
  end

  def pay_refusal(&) = assert_raises(TeamPlanning::Error, &).message

  # Pay isn't tracked, so no update carries a pay conflict: the plan is made to report one for Q1.
  def with_pay_conflict_carried(&)
    real_new = TeamPlanning::PlanAggregate.method(:new)
    scenario_id = @q1
    key = [ @brook.id, "data:pay" ]
    forcing = lambda do
      real_new.call.tap do |plan|
        plan.define_singleton_method(:carried_conflicts) do |id|
          id == scenario_id ? super(id).merge(key => BASE_ON) : super(id)
        end
      end
    end
    TeamPlanning::PlanAggregate.stub(:new, forcing, &)
  end

  should "keep the plan in the scenario that made the change, which status reads as settled and history as kept" do
    rebase
    assert_equal "conflicting", brook(@q1)[:status].to_s

    assert_equal({ plan_id: @plan_id, scenario_id: @q1, subject_id: @brook.id, facet: "level", choice: "plan" }, settle(@q1, "plan"))
    status = brook(@q1)
    assert_equal [ "pending", nil ], [ status[:status].to_s, status[:since] ]
    assert_equal({ value: "Promised in March" }, status[:note])

    entry = last_entry(@q1)
    assert_equal [ "set", { "since" => "2026-03-25", "choice" => "plan" } ], entry.values_at(:action, :settles)
    assert_equal [ "level" ], entry[:sealed_fields]
  end

  should "keep the plan where the scenario inherits a sealed level, by setting it there, the parent left alone" do
    rebase
    parent = map(@q1)
    settle(@lean, "plan", note: "Still promised")

    assert_equal "pending", brook(@lean)[:status].to_s
    assert_equal({ value: "Still promised" }, brook(@lean)[:note])
    assert_equal [ "set", { "since" => "2026-03-25", "choice" => "plan" } ], last_entry(@lean).values_at(:action, :settles)
    assert_equal parent, map(@q1)
    assert_equal "conflicting", brook(@q1)[:status].to_s
  end

  should "follow reality in one child alone, the parent and a sibling byte-identical before and after" do
    rebase
    parent, sibling = map(@q1), map(@bold)
    settle(@lean, "reality")

    assert_equal "done", brook(@lean)[:status].to_s, "the plan's 4 would read pending; only the Org Graph's 5 reads done"
    assert_equal [ "set", { "since" => "2026-03-25", "choice" => "reality" } ], last_entry(@lean).values_at(:action, :settles)
    assert_equal parent, map(@q1)
    assert_equal sibling, map(@bold)
    assert_equal "conflicting", brook(@bold)[:status].to_s
  end

  should "leave an ordinary edit unmarked" do
    call(:SetPlannedLevel, plan_id: @plan_id, scenario_id: @q1, person_id: @brook.id, level: "6")

    assert_nil last_entry(@q1)[:settles]
  end

  should "refuse a conflict no update carried forward, and a viewer" do
    assert_equal "conflicting", brook(@q1)[:status].to_s
    assert_match(/nothing to settle: update the plan to today first/, refusal { settle(@q1, "plan") })

    rebase
    assert_equal "No such plan", refusal { settle(@q1, "plan", as: @viewer) }
    assert_equal "conflicting", brook(@q1)[:status].to_s
  end

  context "a pay conflict, which no update carries today, so the test forces one" do
    setup do
      call(:SetActualPay, plan_id: @plan_id, scenario_id: @q1, person_id: @brook.id, amount: "91234", currency: "AUD", period: "year", basis: "actual")
      rebase
      @colleague = as_tenant { create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant)) }
      as_tenant { handler.add_member(@plan_id, @colleague.person_id, role: "editor") }
    end

    should "refuse an editor without the see-pay right, saying nothing about the conflict or the pay, and let a holder keep the plan" do
      forced = pay_refusal { with_pay_conflict_carried { settle_pay(as: @colleague) } }
      unforced = pay_refusal { settle_pay(as: @colleague) }

      assert_equal "Only a member with the see-pay right can change pay", forced
      assert_equal unforced, forced
      assert_no_pay_figure forced, "91234"

      with_pay_conflict_carried { settle_pay(as: @editor) }
      entry = call(:History, plan_id: @plan_id, scenario_id: @q1)[:entries].last
      assert_equal [ "data:pay", "set", { "since" => BASE_ON.iso8601, "choice" => "plan" } ], entry.values_at(:facet, :action, :settles)
    end
  end

  should "refuse a choice that is neither keeping the plan nor following reality, before reading the plan" do
    rebase
    assert_match(/choice must be one of \["plan", "reality"\], got "keep"/, refusal { settle(@q1, "keep") })
  end

  should "refuse a carried conflict the Org Graph has since caught up with" do
    rebase
    travel_to(Time.utc(2026, 3, 26, 9)) { as_tenant { @org.change_level(@brook.id, "4", **ESPALIA, effective_on: "2026-03-26") } }
    travel_to Time.utc(2026, 3, 28, 9)
    assert_equal "done", brook(@q1)[:status].to_s

    assert_equal "Status doesn't read this as conflicting, so there is nothing to settle", refusal { settle(@q1, "plan") }
  end

  should "refuse to follow reality for a succession, whose retired units wouldn't follow it" do
    structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    squads, payments, platform, money, core = Array.new(5) { SecureRandom.uuid_v7 }
    travel_to(Time.utc(2026, 2, 1, 9)) do
      as_tenant do
        structure.define_taxonomy([ { level_id: squads, name: "Squad" } ], effective_on: "2026-01-01")
        { payments => "Payments", platform => "Platform", money => "Money", core => "Core" }.each do |id, name|
          structure.create_unit(id, name, level_id: squads, effective_on: "2026-01-01")
        end
      end
    end
    succession = call(:SetUnitSuccession, plan_id: @plan_id, scenario_id: @q1, predecessor_ids: [ payments, platform ],
                                          successor_ids: [ money ])[:succession_id]
    travel_to(Time.utc(2026, 3, 20, 9)) do
      as_tenant { structure.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ payments ], successor_ids: [ core ], effective_on: "2026-03-20") }
    end
    rebase

    assert_match(/A succession can't follow reality yet/,
                 refusal { call(:SettleConflict, plan_id: @plan_id, scenario_id: @q1, subject_id: succession, facet: "succession", choice: "reality") })
  end

  should "follow a level the Org Graph cleared, which then reads as no level and done" do
    rebase
    travel_to(Time.utc(2026, 3, 26, 9)) { as_tenant { @org.change_level(@brook.id, nil, **ESPALIA, effective_on: "2026-03-26") } }
    travel_to Time.utc(2026, 3, 28, 9)
    settle(@q1, "reality")

    assert_equal [ "done", nil ], brook(@q1).values_at(:status, :since)
    assert_equal({ "since" => "2026-03-25", "choice" => "reality" }, last_entry(@q1)[:settles])
    people = call(:ScenarioMap, plan_id: @plan_id, scenario_id: @q1)[:people]
    assert_equal({ value: nil }, people.find { it[:id] == @brook.id }[:planned_level])
    assert_no_match(/"planned_level":\{"value":""\}/, map(@q1))

    as_tenant { PlanKeyStore.new.destroy_person(@brook.id) }
    assert_equal({ removed: true }, call(:ScenarioMap, plan_id: @plan_id, scenario_id: @q1)[:people].find { it[:id] == @brook.id }[:planned_level])
    assert_equal "unknown", brook(@q1)[:status].to_s
  end

  should "follow a membership the Org Graph holds with no allocation, which the map and capacity read as unknown" do
    squads, payments = Array.new(2) { SecureRandom.uuid_v7 }
    as_tenant do
      structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
      structure.define_taxonomy([ { level_id: squads, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(payments, "Payments", level_id: squads, effective_on: "2026-01-01")
    end
    call(:SetAssignment, plan_id: @plan_id, scenario_id: @q1, person_id: @brook.id, placements: [ { unit_id: payments, allocation: 1 } ])
    travel_to(Time.utc(2026, 3, 26, 9)) { as_tenant { @org.set_membership(@brook.id, payments, **ESPALIA, effective_on: "2026-03-26") } }
    travel_to Time.utc(2026, 3, 27, 9)
    rebase
    settle(@q1, "reality", facet: "assignment")

    assignment = call(:Status, plan_id: @plan_id, scenario_id: @q1)[:statuses].find { it[:subject_id] == @brook.id && it[:facet] == "assignment" }
    assert_equal [ "done", nil ], assignment.values_at(:status, :since)
    person = call(:ScenarioMap, plan_id: @plan_id, scenario_id: @q1)[:people].find { it[:id] == @brook.id }
    assert_equal [ [ payments, nil ] ], person[:memberships].map { it.values_at(:unit_id, :allocation) }
    place = call(:Capacity, plan_id: @plan_id, scenario_id: @q1)[:seats].find { it[:seat_id] == @brook.id }[:places].sole
    assert_equal [ payments, "1", false ], place.values_at(:unit_id, :allocation, :allocation_known)
  end

  should "keep the plan on a scenario's own pin as a pin of the same change, the overrides row still pinned" do
    call(:SetDeparture, plan_id: @plan_id, scenario_id: @plan_id, person_id: @brook.id)
    call(:WithdrawDeparture, plan_id: @plan_id, scenario_id: @q1, person_id: @brook.id)
    call(:PinChange, plan_id: @plan_id, scenario_id: @lean, subject_id: @brook.id, facet: "departure")
    pinned = departure_override(@lean)
    assert_equal @q1, pinned[:pinned_from][:scenario_id]
    travel_to(Time.utc(2026, 3, 20, 9)) { as_tenant { @org.leave(@brook.id, **ESPALIA, effective_on: "2026-03-20") } }
    rebase
    departure = -> { call(:Status, plan_id: @plan_id, scenario_id: @lean)[:statuses].find { it[:subject_id] == @brook.id && it[:facet] == "departure" } }
    assert_equal "2026-03-25", departure.call[:since]

    settle(@lean, "plan", facet: "departure")
    assert_nil departure.call[:since]

    assert_equal [ "pin", { "since" => "2026-03-25", "choice" => "plan" } ], last_entry(@lean).values_at(:action, :settles)
    kept = departure_override(@lean)
    assert kept[:pinned]
    assert_equal pinned[:pinned_from], kept[:pinned_from]
  end

  should "refuse to follow reality for a withdrawn departure once the person has left, while keeping the plan still works" do
    call(:SetDeparture, plan_id: @plan_id, scenario_id: @plan_id, person_id: @brook.id)
    call(:WithdrawDeparture, plan_id: @plan_id, scenario_id: @q1, person_id: @brook.id)
    travel_to(Time.utc(2026, 3, 20, 9)) { as_tenant { @org.leave(@brook.id, **ESPALIA, effective_on: "2026-03-20") } }
    rebase
    withdrawal = call(:Status, plan_id: @plan_id, scenario_id: @q1)[:statuses].find { it[:subject_id] == @brook.id && it[:facet] == "departure" }
    assert_equal "conflicting", withdrawal[:status].to_s

    assert_match(/has this person leaving, so a withdrawn departure can't follow reality/,
                 refusal { settle(@q1, "reality", facet: "departure") })
    settle(@q1, "plan", facet: "departure")
    assert_equal "plan", last_entry(@q1)[:settles]["choice"]
  end
end
