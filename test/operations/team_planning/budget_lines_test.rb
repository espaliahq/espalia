# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::BudgetLinesTest < ActiveSupport::TestCase
  FACET = TeamPlanning::Events::BudgetLineSet.facet
  YEAR = { starts_on: "2026-07-01", ends_on: "2027-06-30" }.freeze

  setup do
    @tenant = create(:tenant)
    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      @editor = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @viewer = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      @outsider = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
      @engineers = BudgetLine.create!(**YEAR, origin: "new", amount: 480_000, currency: "AUD", period: "year", head_count: 4)
      @support = BudgetLine.create!(**YEAR, origin: "existing", head_count: 2)
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: "2026-03-02")[:plan_id]
    call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @viewer.person_id, role: "viewer")
    @q1 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, relation: "then", name: "Q1", ends_on: "2026-06-30")[:scenario_id]
    @q2 = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, parent_id: @q1, relation: "then", name: "Q2",
                                                       ends_on: "2026-09-30")[:scenario_id]
  end

  def as_tenant(tenant = @tenant, &) = ActsAsTenant.with_tenant(tenant, &)

  def call(operation, as: @editor, **params)
    as_tenant { operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:) }
  end

  def set(scenario_id: @q1, **params)
    call(Operations::TeamPlanning::SetBudgetLine, plan_id: @plan_id, scenario_id:, **YEAR, origin: "new", **params)
  end

  def cut(line_id, scenario_id: @q1) = call(Operations::TeamPlanning::CutBudgetLine, plan_id: @plan_id, scenario_id:, budget_line_id: line_id)

  def lines(scenario_id = @q2, as: @editor) = call(Operations::TeamPlanning::BudgetLines, as:, plan_id: @plan_id, scenario_id:)

  def line(id, scenario_id = @q2) = lines(scenario_id)[:budget_lines].find { it[:budget_line_id] == id }

  def refusal(as: @editor, &)
    assert_raises(Operations::Base::ParameterError, &).message
  end

  def attention(scenario_id = @q2) = call(Operations::TeamPlanning::Attention, plan_id: @plan_id, scenario_id:)[:items].select { it[:check] == "budget_lines" }

  should "give every scenario the organisation's lines, an amount in its own currency and a head count with no amount" do
    assert_equal [ [ @engineers.id, "tenant", "480000.00", "AUD", "year", "4.00" ], [ @support.id, "tenant", nil, nil, nil, "2.00" ] ],
                 lines(@plan_id)[:budget_lines].map { it.values_at(:budget_line_id, :source, :amount, :currency, :period, :head_count) }
    assert_equal lines(@plan_id)[:budget_lines], lines[:budget_lines]
    assert_empty lines[:orphaned]
  end

  # A budget amount is pay ([#367](https://github.com/espaliahq/espalia/issues/367)), and a period
  # or currency is only there beside one, so all three hide alike.
  should "give a member without the see-pay right every line and head count, and no amount, currency or period" do
    held, seen = [ @editor, @viewer ].map { lines(@plan_id, as: it) }
    fields = ->(read) { read[:budget_lines].map { it.values_at(:budget_line_id, :amount, :currency, :period, :head_count) } }

    assert_equal [ true, false ], [ held[:money], seen[:money] ]
    assert_equal [ [ @engineers.id, nil, nil, nil, "4.00" ], [ @support.id, nil, nil, nil, "2.00" ] ], fields.(seen)
    assert_equal held[:budget_lines].map(&:keys), seen[:budget_lines].map(&:keys)
    assert_equal seen[:budget_lines].first.except(:budget_line_id, :head_count, :origin), seen[:budget_lines].second.except(:budget_line_id, :head_count, :origin),
                 "a line with a hidden amount reads exactly as one with none"
    [ "480000", "AUD" ].each { assert_not_includes seen.to_json, it }
  end

  should "change a tenant line by its id and add a plan line, each reaching the steps after and not before" do
    assert_equal({ plan_id: @plan_id, scenario_id: @q1, budget_line_id: @engineers.id, source: "changed" },
                 set(budget_line_id: @engineers.id, amount: "520000", currency: "AUD", period: "year", head_count: "5"))
    added = set(amount: "9000", currency: "NZD", period: "month", cost_centre: " Platform ")

    assert_equal [ "changed", "520000.00", "5.00" ], line(@engineers.id).values_at(:source, :amount, :head_count)
    assert_equal [ "plan", "9000.00", "NZD", "month", "Platform" ],
                 line(added[:budget_line_id]).values_at(:source, :amount, :currency, :period, :cost_centre)
    assert_equal "480000.00", line(@engineers.id, @plan_id)[:amount]
    assert_nil line(added[:budget_line_id], @plan_id)
  end

  should "reach every scenario that hasn't changed a line when the organisation changes it, and none that has" do
    set(budget_line_id: @support.id, head_count: "3")
    as_tenant do
      @support.update!(head_count: 6)
      @engineers.update!(amount: 500_000)
    end

    assert_equal "3.00", line(@support.id)[:head_count]
    assert_equal "6.00", line(@support.id, @plan_id)[:head_count]
    assert_equal "500000.00", line(@engineers.id)[:amount]
  end

  should "cut a line, bring it back by setting it again, and undo and clear like any change" do
    cut(@engineers.id)
    assert_nil line(@engineers.id)

    set(scenario_id: @q2, budget_line_id: @engineers.id, head_count: "1")
    assert_equal [ "changed", "1.00" ], line(@engineers.id).values_at(:source, :head_count)

    call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @q2)
    assert_nil line(@engineers.id)

    call(Operations::TeamPlanning::ClearChange, plan_id: @plan_id, scenario_id: @q1, subject_id: @engineers.id, facet: FACET)
    assert_equal "tenant", line(@engineers.id)[:source]
  end

  should "bring back a line the plan added after a scenario cuts it" do
    added = set(head_count: "2")[:budget_line_id]
    cut(added, scenario_id: @q2)
    assert_nil line(added)

    assert_equal "plan", set(scenario_id: @q2, budget_line_id: added, head_count: "3")[:source]
    assert_equal [ "plan", "3.00" ], line(added).values_at(:source, :head_count)
  end

  should "keep a level that has left the framework when a scenario sets its line again, after a set or a cut of either kind of line" do
    level = as_tenant do
      role = create(:framework_role, tenant: @tenant, name: "Software Engineer")
      create(:framework_level, tenant: @tenant, role_id: role.role_id, code: "E2", title: "Engineer II")
    end
    as_tenant { @support.tap { it.take_level(level) }.save! }
    added, added_then_cut = Array.new(2) { set(head_count: "1", level_id: level.level_id)[:budget_line_id] }
    [ added_then_cut, @support.id ].each { cut(it) }
    as_tenant { level.destroy! }

    [ added, added_then_cut, @support.id ].each do |id|
      set(scenario_id: @q2, budget_line_id: id, origin: "existing", head_count: "2", level_id: level.level_id)
      assert_equal [ level.level_id, "E2 Engineer II" ], line(id).values_at(:level_id, :level_name)
    end
  end

  should "keep a line the organisation removed orphaned when a scenario sets it again" do
    set(budget_line_id: @engineers.id, head_count: "5")
    as_tenant { @engineers.destroy! }

    assert_equal "changed", set(scenario_id: @q2, budget_line_id: @engineers.id, head_count: "6")[:source]
    assert_equal [ { budget_line_id: @engineers.id, kind: "set" } ], lines[:orphaned]
    assert_equal [ @engineers.id ], attention.map { it[:subject_id] }
  end

  should "keep a change to a line the organisation removed, listed as orphaned and flagged by Attention" do
    set(budget_line_id: @engineers.id, head_count: "5")
    cut(@support.id, scenario_id: @q2)
    as_tenant { BudgetLine.where(id: [ @engineers.id, @support.id ]).destroy_all }

    read = lines
    assert_empty read[:budget_lines]
    assert_equal [ { budget_line_id: @engineers.id, kind: "set" }, { budget_line_id: @support.id, kind: "cut" } ], read[:orphaned]
    assert_equal [ [ @engineers.id, FACET, "Changes a budget line the organisation has since removed", "BudgetLineSet" ],
                   [ @support.id, FACET, "Cuts a budget line the organisation has since removed", "BudgetLineCut" ] ],
                 attention.map { [ *it.values_at(:subject_id, :facet, :reason), it.dig(:change, :kind) ] }
    assert_empty attention(@plan_id)
  end

  should "refuse the baseline, a line the scenario doesn't hold, and a broken line, never repeating a figure" do
    baseline = "The baseline holds the organisation's approved budget as it is: change a line in a scenario"
    assert_equal baseline, refusal { set(scenario_id: @plan_id, head_count: "1") }
    assert_equal baseline, refusal { cut(@engineers.id, scenario_id: @plan_id) }

    unknown = SecureRandom.uuid_v7
    assert_equal "This scenario has no such budget line", refusal { set(budget_line_id: unknown, head_count: "1") }
    assert_equal "This scenario has no such budget line", refusal { cut(unknown) }

    assert_equal "A budget line needs an amount, a head count or both", refusal { set }
    assert_equal "amount must be a number with at most two decimal places", refusal { set(amount: "52,50", currency: "AUD", period: "year") }
    assert_equal "Currency #{Currency::INVALID}", refusal { set(amount: "777", currency: "ZZZ", period: "year") }
  end

  should "show the lines to plan members only, and let only editors change them" do
    assert_equal 2, lines(as: @viewer)[:budget_lines].size
    assert_equal "No such plan", refusal { lines(as: @outsider) }
    assert_equal "No such plan", refusal { call(Operations::TeamPlanning::SetBudgetLine, as: @viewer, plan_id: @plan_id, scenario_id: @q1, **YEAR, origin: "new", head_count: "1") }
    assert_equal "No such plan", refusal { call(Operations::TeamPlanning::CutBudgetLine, as: @outsider, plan_id: @plan_id, scenario_id: @q1, budget_line_id: @engineers.id) }
  end

  # A budget amount is pay ([#367](https://github.com/espaliahq/espalia/issues/367)), so an editor
  # without the see-pay right works on head counts alone.
  context "an editor without the see-pay right" do
    setup do
      @planner = as_tenant { create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant)) }
      call(Operations::TeamPlanning::AddPlanMember, plan_id: @plan_id, person_id: @planner.person_id, role: "editor")
    end

    should "add and change lines by head count, and set no amount, currency or period" do
      added = set_as_planner(head_count: "2")[:budget_line_id]
      set_as_planner(budget_line_id: added, head_count: "3")
      set_as_planner(budget_line_id: @support.id, head_count: "5")
      assert_equal [ "3.00", "5.00" ], [ line(added)[:head_count], line(@support.id)[:head_count] ]

      [ { amount: "100", currency: "AUD", period: "year" }, { currency: "AUD" }, { period: "year" } ].each do |money|
        assert_equal "Setting a budget amount needs the see-pay right.", refusal { set_as_planner(head_count: "1", **money) }
      end
      cut_as_planner(@support.id)
      assert_nil line(@support.id)
    end

    should "refuse to change or cut a line that carries an amount, the organisation's or the plan's" do
      priced = set(amount: "9000", currency: "AUD", period: "month")[:budget_line_id]
      [ @engineers.id, priced ].each do |id|
        assert_equal PRICED, refusal { set_as_planner(budget_line_id: id, head_count: "1") }
        assert_equal PRICED, refusal { cut_as_planner(id) }
      end
      assert_equal "This scenario has no such budget line", refusal { cut_as_planner(SecureRandom.uuid_v7) }
    end

    should "treat a line the plan once priced as priced, even after that change is undone" do
      set(budget_line_id: @support.id, amount: "9000", currency: "AUD", period: "month", head_count: "2")
      call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @q1)
      assert_nil line(@support.id)[:amount]

      assert_equal PRICED, refusal { set_as_planner(budget_line_id: @support.id, head_count: "1") }
    end

    should "undo their own change to a line with no amount" do
      set_as_planner(budget_line_id: @support.id, head_count: "5")
      call(Operations::TeamPlanning::UndoChange, as: @planner, plan_id: @plan_id, scenario_id: @q1)
      assert_equal "tenant", line(@support.id)[:source]
      call(Operations::TeamPlanning::RedoChange, as: @planner, plan_id: @plan_id, scenario_id: @q1)
      assert_equal "5.00", line(@support.id)[:head_count]
    end

    should "neither undo, redo, clear nor note a change to a line that carries an amount, and skip it by default" do
      set_as_planner(budget_line_id: @support.id, head_count: "5")
      as_tenant { @support.update!(amount: 90_000, currency: "AUD", period: "year") }
      event_id = change_of(@support.id)

      assert_equal "You have nothing here to undo", refusal { undo_as_planner }
      assert_equal PRICED, refusal { undo_as_planner(event_id:) }
      assert_equal PRICED, refusal { call(Operations::TeamPlanning::ClearChange, as: @planner, plan_id: @plan_id, scenario_id: @q1, subject_id: @support.id, facet: FACET) }
      assert_equal "Noting a budget line change needs the see-pay right.",
                   refusal { call(Operations::TeamPlanning::NoteChange, as: @planner, plan_id: @plan_id, scenario_id: @q1, event_id:, note: "Fine") }

      undo_as_holder = call(Operations::TeamPlanning::UndoChange, plan_id: @plan_id, scenario_id: @q1, event_id:)
      assert undo_as_holder[:undone]
      assert_equal PRICED, refusal { call(Operations::TeamPlanning::RedoChange, as: @planner, plan_id: @plan_id, scenario_id: @q1, event_id:) }
      assert_equal "You have nothing here to redo", refusal { call(Operations::TeamPlanning::RedoChange, as: @planner, plan_id: @plan_id, scenario_id: @q1) }
    end

    should "be offered undo, redo and clear on a change to a line with no amount, and none on one that carries an amount" do
      set_as_planner(budget_line_id: @support.id, head_count: "5")
      set_as_planner(budget_line_id: @support.id, head_count: "6")
      latest, nothing_to_redo, clearable = offers
      assert_equal [ true, nil, true ], [ latest.present?, nothing_to_redo, clearable ]

      undo_as_planner
      assert_equal latest, offers.second

      as_tenant { @support.update!(amount: 90_000, currency: "AUD", period: "year") }
      assert_equal [ nil, nil, false ], offers
    end

    # A pin would copy a priced line's amount, so it needs a rule of its own before it may land.
    should "refuse a pin on a priced line in the same words as one on a line with no amount" do
      pin = ->(id) { call(Operations::TeamPlanning::PinChange, as: @planner, plan_id: @plan_id, scenario_id: @q2, subject_id: id, facet: FACET) }
      priced = set(amount: "9000", currency: "AUD", period: "month", head_count: "3")[:budget_line_id]

      assert_equal 1, [ @engineers.id, priced, @support.id ].map { |id| refusal { pin.(id) } }.uniq.size
    end

    should "read a priced line's history and override exactly as a line with a head count alone" do
      priced = set(amount: "9000", currency: "AUD", period: "month", head_count: "3")[:budget_line_id]
      plain = set(head_count: "3")[:budget_line_id]
      set(budget_line_id: priced, amount: "9500", currency: "AUD", period: "month", head_count: "3", scenario_id: @q2)
      set(budget_line_id: plain, head_count: "3", scenario_id: @q2)
      set(budget_line_id: @engineers.id, amount: "480000", currency: "AUD", period: "year", head_count: "5", scenario_id: @q2)

      history = ->(as) { call(Operations::TeamPlanning::History, as:, plan_id: @plan_id, scenario_id: @q1)[:entries].index_by { it[:subject_id] } }
      overrides = ->(as) { call(Operations::TeamPlanning::Overrides, as:, plan_id: @plan_id, scenario_id: @q2)[:overrides].index_by { it[:subject_id] } }
      held, seen = history.(@editor), history.(@planner)
      held_q2, seen_q2 = overrides.(@editor), overrides.(@planner)

      assert_equal [ "AUD", [ "amount" ] ], [ held[priced][:end_state]["currency"], held[priced][:sealed_fields] ]
      assert_equal [ "AUD", "AUD" ], [ held_q2[priced], held_q2[@engineers.id] ].map { it[:inherits][:end_state]["currency"] }
      assert_nil held_q2[@engineers.id][:inherits][:scenario_id], "read off the parent's map, not an override above"
      assert_equal seen[plain].values_at(:end_state, :sealed_fields), seen[priced].values_at(:end_state, :sealed_fields)
      assert_equal seen_q2[plain].values_at(:end_state, :inherits), seen_q2[priced].values_at(:end_state, :inherits)
      assert_equal %w[head_count tenant_line], seen_q2[@engineers.id][:end_state].keys.grep(/head_count|tenant_line|currency|period|amount/).sort
      [ "AUD", "9000", "9500", "480000", "month" ].each { assert_not_includes [ seen, seen_q2 ].to_json, it }
    end
  end

  PRICED = "Changing this budget line needs the see-pay right."

  def set_as_planner(scenario_id: @q1, **params)
    call(Operations::TeamPlanning::SetBudgetLine, as: @planner, plan_id: @plan_id, scenario_id:, **YEAR, origin: "new", **params)
  end

  def cut_as_planner(line_id) = call(Operations::TeamPlanning::CutBudgetLine, as: @planner, plan_id: @plan_id, scenario_id: @q1, budget_line_id: line_id)

  def undo_as_planner(**params) = call(Operations::TeamPlanning::UndoChange, as: @planner, plan_id: @plan_id, scenario_id: @q1, **params)

  # @return [Array] what the planner's Undo and Redo would step, and whether they may clear @support's change
  def offers
    step = call(Operations::TeamPlanning::UndoStep, as: @planner, plan_id: @plan_id, scenario_id: @q1)
    status = call(Operations::TeamPlanning::Status, as: @planner, plan_id: @plan_id, scenario_id: @q1)[:statuses].find { it[:subject_id] == @support.id }
    [ step[:undo]&.dig(:event_id), step[:redo]&.dig(:event_id), status[:clearable] ]
  end

  def change_of(line_id, scenario_id = @q1)
    call(Operations::TeamPlanning::History, plan_id: @plan_id, scenario_id:)[:entries].find { it[:subject_id] == line_id && it[:facet] == FACET }[:event_id]
  end

  should "shred a plan's own amount with the plan, leaving the organisation's line as it was" do
    added = set(amount: "70000", currency: "AUD", period: "year")[:budget_line_id]
    repository = TeamPlanning::Repository.new
    change = as_tenant { repository.sealed(repository.load_plan(@plan_id).winning_changes(@q1)) }[[ added, FACET ]]
    assert_equal "70000.00", change.data[:amount].reveal

    call(Operations::TeamPlanning::DeletePlan, plan_id: @plan_id)

    stored = Rails.configuration.event_store.read.event(change.event_id)
    assert_predicate stored.data[:amount], :removed?
    assert_equal 480_000, as_tenant { @engineers.reload.amount }
  end
end
