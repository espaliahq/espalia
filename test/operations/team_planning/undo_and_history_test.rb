# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::UndoAndHistoryTest < ActiveSupport::TestCase
  SYSTEM = OrgGraph::Authorization::SYSTEM
  CAP = "rule:test_headcount_cap"

  class HeadcountCap < TeamPlanning::RuleKind
    def self.rule_name = "test_headcount_cap"
    def self.description = "The most people a unit may hold"
    def self.default = { "cap" => 10 }
  end

  setup do
    TeamPlanning::RuleKinds.register(HeadcountCap)
    @tenant = create(:tenant)
    departments = @departments = SecureRandom.uuid_v7
    @engineering = SecureRandom.uuid_v7

    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
      structure.define_taxonomy([ { level_id: departments, name: "Department" } ], effective_on: "2026-01-01")
      structure.create_unit(@engineering, "Engineering", level_id: departments, effective_on: "2026-01-01")

      @editor = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant, name: "Ada Editor"))
      @viewer = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @outsider = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @plan_id = SecureRandom.uuid_v7
      handler.create_plan(@plan_id, name: "Next year", base_on: Date.new(2026, 3, 2))
      handler.add_member(@plan_id, @viewer.person_id, role: "viewer")
      @q1 = fork(@plan_id, "then", "Q1", ends_on: "2026-06-30")
      @lean = fork(@q1, "instead", "Lean Q1")
    end
  end

  teardown { TeamPlanning::RuleKinds.unregister(HeadcountCap) }

  def as_tenant(tenant = @tenant, &) = ActsAsTenant.with_tenant(tenant, &)

  def context_for(account) = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)

  def handler = TeamPlanning::CommandHandler.new(actor: context_for(@editor))

  def fork(parent_id, relation, name, ends_on: nil)
    SecureRandom.uuid_v7.tap { handler.fork_scenario(@plan_id, it, parent_id:, relation:, name:, ends_on:) }
  end

  def set_cap(scenario_id, cap, subject_id: @plan_id)
    as_tenant do
      handler.set_change(@plan_id, TeamPlanning::Events::RuleSet, scenario_id:, subject_id:,
                                                                   end_state: { rule: "test_headcount_cap", value: { cap: } })
    end
  end

  def call(operation, as: @editor, **params)
    as_tenant { "Operations::TeamPlanning::#{operation}".constantize.call(context: context_for(as), params:) }
  end

  def history(scenario_id, as: @editor) = call(:History, as:, plan_id: @plan_id, scenario_id:)[:entries]

  def caps(scenario_id) = call(:Overrides, plan_id: @plan_id, scenario_id:)[:overrides].map { it.dig(:end_state, "value", "cap") }

  def undo_change(scenario_id, as: @editor, **) = call(:UndoChange, as:, plan_id: @plan_id, scenario_id:, **)

  def redo_change(scenario_id, as: @editor, **) = call(:RedoChange, as:, plan_id: @plan_id, scenario_id:, **)

  def refusal(&) = assert_raises(Operations::Base::ParameterError, &).message

  def set_period(scenario_id, ends_on)
    call(:SetScenarioPeriod, plan_id: @plan_id, scenario_id:, ends_on:)
    history(scenario_id).last[:event_id]
  end

  def periods(*ids)
    rows = call(:Scenarios, plan_id: @plan_id)[:scenarios].index_by { it[:scenario_id] }
    ids.map { rows[it].values_at(:starts_on, :ends_on) }
  end

  should "undo the caller's latest change and redo it, saying which change each took" do
    set_cap(@lean, 8)
    set_cap(@lean, 5)
    latest = history(@lean).last[:event_id]

    assert_equal({ plan_id: @plan_id, scenario_id: @lean, event_id: latest, undone: true }, undo_change(@lean))
    assert_equal [ 8 ], caps(@lean)
    assert_equal({ plan_id: @plan_id, scenario_id: @lean, event_id: latest, redone: true }, redo_change(@lean))
    assert_equal [ 5 ], caps(@lean)
  end

  should "undo the change it is given, and name the later one that blocks it" do
    set_cap(@lean, 8)
    set_cap(@lean, 5)
    first, second = history(@lean).pluck(:event_id)

    assert_equal "A later change to this replaced it (#{second}): undo that first, then undo this", refusal { undo_change(@lean, event_id: first) }
    undo_change(@lean, event_id: second)
    undo_change(@lean, event_id: first)
    assert_empty caps(@lean)
  end

  should "list the history oldest first, with who did each and what stands undone" do
    set_cap(@q1, 8)
    undo_change(@q1)

    set, undone = history(@q1)
    assert_equal({ event_id: set[:event_id], action: "set", subject_id: @plan_id, facet: CAP, kind: "rule_set",
                   end_state: { "rule" => "test_headcount_cap", "value" => { "cap" => 8 } }, sealed_fields: [],
                   reverses_event_id: nil, by: { person_id: @editor.person_id, name: "Ada Editor" }, at: "2026-02-01T09:00:00Z",
                   undone: { by: { person_id: @editor.person_id, name: "Ada Editor" }, at: "2026-02-01T09:00:00Z" } }.compact,
                 set)
    assert_equal [ "undo", set[:event_id] ], undone.values_at(:action, :reverses_event_id)
  end

  should "page the history, oldest first" do
    set_cap(@q1, 8)
    set_cap(@q1, 9)
    set_cap(@q1, 10)

    Operations::TeamPlanning::History.stub(:per_page, 2) do
      first = call(:History, plan_id: @plan_id, scenario_id: @q1)
      second = call(:History, plan_id: @plan_id, scenario_id: @q1, page: 2)

      assert_equal [ 1, true, [ 8, 9 ] ], [ first[:page], first[:next_page], first[:entries].map { it.dig(:end_state, "value", "cap") } ]
      assert_equal [ 2, false, [ 10 ] ], [ second[:page], second[:next_page], second[:entries].map { it.dig(:end_state, "value", "cap") } ]
    end
  end

  should "undo a unit's retirement and then its creation, a step at a time" do
    unit_id = call(:SetUnit, plan_id: @plan_id, scenario_id: @lean, name: "Payments", top_level: true, level_id: @departments)[:unit_id]
    call(:RetireUnit, plan_id: @plan_id, scenario_id: @lean, unit_id:)
    units = -> { call(:ScenarioMap, plan_id: @plan_id, scenario_id: @lean)[:units].pluck(:name) }
    assert_not_includes units.call, "Payments"

    undo_change(@lean)
    assert_includes units.call, "Payments"
    assert_equal [ "unit_set" ], call(:Overrides, plan_id: @plan_id, scenario_id: @lean)[:overrides].pluck(:kind)

    undo_change(@lean)
    assert_not_includes units.call, "Payments"
    assert_empty call(:Overrides, plan_id: @plan_id, scenario_id: @lean)[:overrides]
    assert_equal [ %w[set unit_set], %w[set unit_retired], [ "undo", nil ], [ "undo", nil ] ], history(@lean).map { it.values_at(:action, :kind) }
  end

  should "undo an assignment, keeping its placements in the history" do
    person_id = @viewer.person_id
    placements = [ { unit_id: @engineering, allocation: 0.5 } ]
    call(:SetAssignment, plan_id: @plan_id, scenario_id: @lean, person_id:, placements:)
    resolved = -> { call(:ScenarioMap, plan_id: @plan_id, scenario_id: @lean).values_at(:people, :unresolved).flatten.to_s }
    assert_includes resolved.call, person_id

    undo_change(@lean)
    assert_not_includes resolved.call, person_id
    assert_equal [ { "unit_id" => @engineering, "position_id" => nil, "allocation" => 0.5, "role" => nil } ],
                 history(@lean).first.dig(:end_state, "placements")
  end

  should "name a pin's source in the history" do
    set_cap(@q1, 8)
    as_tenant { handler.pin_change(@plan_id, scenario_id: @lean, subject_id: @plan_id, facet: CAP) }

    assert_equal @q1, history(@lean).sole.dig(:pinned_from, :scenario_id)
  end

  should "name a forgotten actor as a former member" do
    set_cap(@lean, 5)
    undo_change(@lean)
    as_tenant { @editor.person.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current) }

    set, undone = history(@lean, as: @viewer)
    assert_equal [ Person::FORMER_MEMBER ] * 3, [ set.dig(:by, :name), set.dig(:undone, :by, :name), undone.dig(:by, :name) ]
  end

  context "a date edit" do
    setup do
      @q2 = as_tenant { fork(@q1, "then", "Q2", ends_on: "2026-09-30") }
      @edit = set_period(@q1, "2026-05-31")
    end

    should "undo and redo the caller's latest date edit, moving the next step with it" do
      assert_equal({ plan_id: @plan_id, scenario_id: @q1, event_id: @edit, undone: true }, undo_change(@q1))
      assert_equal [ %w[2026-03-02 2026-06-30], %w[2026-07-01 2026-09-30] ], periods(@q1, @q2)
      assert_equal({ plan_id: @plan_id, scenario_id: @q1, event_id: @edit, redone: true }, redo_change(@q1, event_id: @edit))
      assert_equal [ %w[2026-03-02 2026-05-31], %w[2026-06-01 2026-09-30] ], periods(@q1, @q2)
    end

    should "list the edit marked undone, with its undo and redo beside it" do
      undo_change(@q1)
      redo_change(@q1)

      edit, undone, redone = history(@q1).last(3)
      assert_equal [ "dates", @edit, nil ], [ edit[:action], edit[:event_id], edit[:undone] ]
      assert_equal [ "undo", @edit ], undone.values_at(:action, :reverses_event_id)
      assert_equal [ "redo", @edit ], redone.values_at(:action, :reverses_event_id)
    end

    should "refuse an undo that would leave a later step ending before it starts, naming it" do
      set_period(@q2, "2026-06-15")

      assert_equal "Q2 would end on 2026-06-15, before it starts on 2026-07-01", refusal { undo_change(@q1, event_id: @edit) }
    end

    should "refuse a viewer, and say there is nothing to undo once it is undone" do
      assert_equal "No such plan", refusal { undo_change(@q1, as: @viewer, event_id: @edit) }
      undo_change(@q1)
      assert_equal "You have nothing here to undo", refusal { undo_change(@q1) }
    end

    should "refuse an archived plan" do
      call(:ArchivePlan, plan_id: @plan_id)

      assert_equal TeamPlanning::PlanAggregate::ARCHIVED, refusal { undo_change(@q1, event_id: @edit) }
    end

    should "refuse a frozen plan, to its last editor and to a tenant admin alike" do
      admin = as_tenant { create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant)) }
      as_tenant do
        @editor.person.update!(status: "inactive")
        OrgLeaver.create!(tenant: @tenant, person_id: @editor.person_id, left_on: Date.new(2026, 2, 1))
      end

      [ @editor, admin ].each { |account| assert_equal "No such plan", refusal { undo_change(@q1, as: account, event_id: @edit) } }
    end
  end

  should "refuse when the caller has nothing to undo or redo, and an unknown scenario" do
    assert_equal "You have nothing here to undo", refusal { undo_change(@lean) }
    assert_equal "You have nothing here to redo", refusal { redo_change(@lean) }
    assert_equal "This plan has no such scenario", refusal { history(SecureRandom.uuid_v7) }
    assert_equal "event_id must be a UUID, got \"e1\"", refusal { undo_change(@lean, event_id: "e1") }
  end

  should "leave someone else's change out of the caller's Undo" do
    set_cap(@lean, 5)
    as_tenant { handler.add_member(@plan_id, @outsider.person_id, role: "editor") }

    assert_equal "You have nothing here to undo", refusal { undo_change(@lean, as: @outsider) }
    assert_equal 1, caps(@lean).size
  end

  should "let a viewer read the history, and refuse it undo and redo as an unknown plan" do
    set_cap(@lean, 5)

    assert_equal 1, history(@lean, as: @viewer).size
    event_id = history(@lean).sole[:event_id]
    assert_equal "No such plan", refusal { undo_change(@lean, as: @viewer, event_id:) }
    assert_equal "No such plan", refusal { redo_change(@lean, as: @viewer, event_id:) }
  end

  should "read as an unknown plan to someone not in it, and in another tenant" do
    assert_equal "No such plan", refusal { history(@lean, as: @outsider) }
    assert_equal "No such plan", refusal { undo_change(@lean, as: @outsider) }

    other = create(:tenant)
    stranger = ActsAsTenant.with_tenant(other) { create(:tenant_user, tenant: other, role: :admin, person: create(:person, tenant: other)) }
    error = assert_raises(Operations::Base::ParameterError) do
      ActsAsTenant.with_tenant(other) do
        Operations::TeamPlanning::History.call(context: context_for(stranger), params: { plan_id: @plan_id, scenario_id: @lean })
      end
    end
    assert_equal "No such plan", error.message
  end
end
