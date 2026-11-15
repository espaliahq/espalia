# frozen_string_literal: true

require "test_helper"

# A note says why a change is in the plan, and nothing else: two scenarios
# that differ only in their notes resolve, compare and drift alike.
class Operations::TeamPlanning::ChangeNotesTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  BASE_ON = Date.new(2026, 3, 2)

  setup do
    @tenant = create(:tenant)
    @org = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    travel_to Time.utc(2026, 2, 1, 9)
    as_tenant do
      @editor = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
      @ada = create(:person, tenant: @tenant, name: "Ada Quill")
      @bo = create(:person, tenant: @tenant, name: "Bo Fenwick")
      [ @ada, @bo ].each { @org.record_person(it.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", level: "3") }
    end
    @plan_id = call(Operations::TeamPlanning::CreatePlan, name: "Next year", base_on: BASE_ON.iso8601)[:plan_id]
    @noted = fork("With notes", relation: "then", ends_on: "2026-12-31")
    @plain = fork("Without notes", relation: "instead", parent_id: @noted)
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def call(operation, as: @editor, **params)
    as_tenant { operation.call(context: AuthorizationContext.new(user: as.user, tenant_user: as, person: as.person), params:) }
  end

  def fork(name, **) = call(Operations::TeamPlanning::ForkScenario, plan_id: @plan_id, name:, **)[:scenario_id]

  def write(operation, scenario_id, **params) = call(operation, plan_id: @plan_id, scenario_id:, **params)

  def plan_both(note)
    write(Operations::TeamPlanning::SetPlannedLevel, @noted, person_id: @ada.id, level: "4", note:)
    write(Operations::TeamPlanning::SetPlannedLevel, @plain, person_id: @ada.id, level: "4")
    write(Operations::TeamPlanning::SetReportingLine, @noted, person_id: @bo.id, manager_id: @ada.id, note:)
    write(Operations::TeamPlanning::SetReportingLine, @plain, person_id: @bo.id, manager_id: @ada.id)
  end

  def changes_in(scenario_id)
    stream = EventStreamNaming.plan_stream(@plan_id, tenant: @tenant)
    as_tenant { Rails.configuration.event_store.read.stream(stream).to_a }
      .select { it.is_a?(TeamPlanning::Events::Change) && it.data[:scenario_id] == scenario_id }
  end

  def note(note, as: @editor, event_id: @change_id)
    call(Operations::TeamPlanning::NoteChange, as:, plan_id: @plan_id, scenario_id: @noted, event_id:, note:)
  end

  def refusal(...) = assert_raises(Operations::Base::ParameterError) { note(...) }.message

  def override = call(Operations::TeamPlanning::Overrides, plan_id: @plan_id, scenario_id: @noted)[:overrides].sole

  def history = call(Operations::TeamPlanning::History, plan_id: @plan_id, scenario_id: @noted)[:entries]

  def without_scenario(rows) = rows.map { it.except(:scenario_id, :change_id) }

  should "store the note with the change, sealed under the person's key, and keep it out of the end state" do
    plan_both("Ready since the platform launch")

    level = changes_in(@noted).find { it.is_a?(TeamPlanning::Events::LevelSet) }
    assert_equal "Ready since the platform launch", level.data[:note].reveal
    assert_equal [ :level ], level.data.except(*TeamPlanning::Events::Change::FIELDS).keys
    assert_not changes_in(@plain).any? { it.data.key?(:note) }
  end

  should "resolve, compare, report status and meet drift the same with or without a note" do
    plan_both("Ready since the platform launch")
    travel_to Time.utc(2026, 4, 2, 9)
    as_tenant { @org.change_level(@ada.id, "5", **ESPALIA, effective_on: "2026-04-01") }

    noted_map, plain_map = [ @noted, @plain ].map { call(Operations::TeamPlanning::ScenarioMap, plan_id: @plan_id, scenario_id: it) }
    assert_equal plain_map[:people], noted_map[:people]

    [ TeamPlanning::Events::LevelSet, TeamPlanning::Events::ReportingLineSet ].each do |kind|
      noted, plain = [ @noted, @plain ].map { |id| changes_in(id).find { it.is_a?(kind) } }
      assert kind.same_end_state?(*[ noted, plain ].map { it.data.except(*TeamPlanning::Events::Change::FIELDS) }), kind.name
    end

    statuses = [ @noted, @plain ].map { call(Operations::TeamPlanning::Status, plan_id: @plan_id, scenario_id: it)[:statuses] }
    assert_equal without_scenario(statuses.last), without_scenario(statuses.first).map { it.except(:note) }
    assert_equal %w[conflicting pending], statuses.first.map { it[:status] }.sort
    assert_equal [ { value: "Ready since the platform launch" } ] * 2, statuses.first.map { it[:note] }
    assert statuses.last.none? { it.key?(:note) }

    drifted = call(Operations::TeamPlanning::Drift, plan_id: @plan_id)[:changes].find { it[:person_id] == @ada.id }
    assert_equal [ @noted, @plain ].sort, drifted[:meets].map { it[:scenario_id] }.sort
  end

  should "list the note with the override and the history entry, and read it as removed once the plan's key is gone" do
    write(Operations::TeamPlanning::SetPlannedLevel, @noted, person_id: @ada.id, level: "4", note: "Ready since the platform launch")
    write(Operations::TeamPlanning::SetPlannedLevel, @plain, person_id: @ada.id, level: "4")

    reads = lambda do |scenario_id|
      [ call(Operations::TeamPlanning::Overrides, plan_id: @plan_id, scenario_id:)[:overrides].sole,
        call(Operations::TeamPlanning::History, plan_id: @plan_id, scenario_id:)[:entries].sole ]
    end
    assert_equal [ { value: "Ready since the platform launch" } ] * 2, reads.call(@noted).map { it[:note] }
    assert reads.call(@plain).none? { it.key?(:note) }

    as_tenant { PlanKeyStore.new.destroy_plan(@plan_id) }
    assert_equal [ { removed: true } ] * 2, as_tenant { [ TeamPlanningOverride, TeamPlanningHistoryEntry ].map { it.find_by!(scenario_id: @noted).note } }
      .map { Operations::TeamPlanning::MapPayload.sealed(it) }
  end

  should "pin a change with a note of its own" do
    write(Operations::TeamPlanning::SetReportingLine, @plan_id, person_id: @bo.id, manager_id: @ada.id)
    write(Operations::TeamPlanning::PinChange, @noted, subject_id: @bo.id, facet: "reporting_line", note: "Hold this whatever the baseline does")

    pinned = as_tenant { Rails.configuration.event_store.read.stream(EventStreamNaming.plan_stream(@plan_id, tenant: @tenant)).to_a.last }
    assert_kind_of TeamPlanning::Events::ChangePinned, pinned
    assert_equal "Hold this whatever the baseline does", pinned.data[:note].reveal
  end

  should "treat a blank note as none, and refuse one past the limit" do
    write(Operations::TeamPlanning::SetPlannedLevel, @noted, person_id: @ada.id, level: "4", note: "  ")
    assert_not changes_in(@noted).sole.data.key?(:note)

    error = assert_raises(Operations::Base::ParameterError) do
      write(Operations::TeamPlanning::SetPlannedLevel, @noted, person_id: @ada.id, level: "4", note: "x" * 2_001)
    end
    assert_equal "A note can be at most 2000 characters", error.message
  end

  context "a note rewritten on a change" do
    setup do
      write(Operations::TeamPlanning::SetPlannedLevel, @noted, person_id: @ada.id, level: "4", note: "Ready since the platform launch")
      @change_id = changes_in(@noted).sole.event_id
    end

    should "show each edit in the history, with who made it and when, and the latest on the override" do
      travel 1.hour
      assert_equal({ plan_id: @plan_id, scenario_id: @noted, event_id: @change_id, noted: true }, note("Ready, and asked for it"))
      travel 1.hour
      assert_equal false, note(nil)[:noted]

      set, rewritten, cleared = history
      assert_equal [ "set", "note", "note" ], [ set, rewritten, cleared ].map { it[:action] }
      assert_equal [ { value: "Ready since the platform launch" }, { value: "Ready, and asked for it" }, nil ], [ set, rewritten, cleared ].map { it[:note] }
      assert_equal [ @change_id ] * 2, [ rewritten, cleared ].map { it[:noted_event_id] }
      assert_equal [ { person_id: @editor.person_id, name: @editor.person.name } ] * 2, [ rewritten, cleared ].map { it[:by] }
      assert_equal [ "2026-02-01T10:00:00Z", "2026-02-01T11:00:00Z" ], [ rewritten, cleared ].map { it[:at] }
      assert_not override.key?(:note)
    end

    should "give the change's status its latest note, then none once cleared, and read it as removed once the person is forgotten" do
      status = -> { call(Operations::TeamPlanning::Status, plan_id: @plan_id, scenario_id: @noted)[:statuses].sole }
      note("Ready, and asked for it")
      assert_equal({ value: "Ready, and asked for it" }, status.call[:note])

      as_tenant { PlanKeyStore.new.destroy_person(@ada.id) }
      assert_equal({ removed: true }, status.call[:note])
    end

    should "refuse a new note once the person is forgotten" do
      as_tenant { PlanKeyStore.new.destroy_person(@ada.id) }

      error = assert_raises(Operations::Base::ParameterError) { note("Ready after all") }
      assert_includes error.message, "has been forgotten"
    end

    should "leave a cleared note off the change's status" do
      note(nil)

      assert_not call(Operations::TeamPlanning::Status, plan_id: @plan_id, scenario_id: @noted)[:statuses].sole.key?(:note)
    end

    should "keep every entry in the history once the person is forgotten, with who wrote each and when, the note removed" do
      travel 1.hour
      note("Ready, and asked for it")
      as_tenant { PlanKeyStore.new.destroy_person(@ada.id) }

      assert_equal [ [ "set", { removed: true } ], [ "note", { removed: true } ] ], history.map { it.values_at(:action, :note) }
      assert_equal [ { person_id: @editor.person_id, name: @editor.person.name } ] * 2, history.map { it[:by] }
      assert_equal [ "2026-02-01T09:00:00Z", "2026-02-01T10:00:00Z" ], history.map { it[:at] }
      assert_equal({ removed: true }, override[:note])
    end

    should "follow its change through undo and redo, and never be undone itself" do
      note("Ready, and asked for it")
      write(Operations::TeamPlanning::SetPlannedLevel, @noted, person_id: @ada.id, level: "5")
      write(Operations::TeamPlanning::UndoChange, @noted)
      assert_equal({ value: "Ready, and asked for it" }, override[:note])

      write(Operations::TeamPlanning::RedoChange, @noted)
      assert_not override.key?(:note)
      write(Operations::TeamPlanning::UndoChange, @noted)
      assert_equal({ value: "Ready, and asked for it" }, override[:note])
      ada = call(Operations::TeamPlanning::ScenarioMap, plan_id: @plan_id, scenario_id: @noted)[:people].find { it[:id] == @ada.id }
      assert_equal({ value: "4" }, ada[:planned_level])
    end

    should "refuse a change since cleared, undone or replaced, and one the scenario never made" do
      write(Operations::TeamPlanning::SetPlannedLevel, @noted, person_id: @ada.id, level: "5")
      assert_equal "That change no longer stands in this scenario, so it takes no note", refusal("Too late")

      write(Operations::TeamPlanning::UndoChange, @noted)
      replaced_id = changes_in(@noted).last.event_id
      assert_equal "That change is undone: redo it to note it", refusal("Too late", event_id: replaced_id)

      write(Operations::TeamPlanning::ClearChange, @noted, subject_id: @ada.id, facet: "level")
      assert_equal "That change no longer stands in this scenario, so it takes no note", refusal("Too late")
      assert_equal "This scenario has no such change", refusal("Lost", event_id: SecureRandom.uuid)
    end

    should "refuse a frozen plan, to its last editor and to a tenant admin alike" do
      admin = as_tenant { create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant)) }
      as_tenant do
        @editor.person.update!(status: "inactive")
        OrgLeaver.create!(tenant: @tenant, person_id: @editor.person_id, left_on: Date.new(2026, 2, 1))
      end

      [ @editor, admin ].each { assert_equal "No such plan", refusal("Frozen", as: it) }
      assert_equal 1, as_tenant { TeamPlanningHistoryEntry.where(plan_id: @plan_id).count }
    end
  end
end
