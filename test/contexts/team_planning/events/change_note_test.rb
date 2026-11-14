# frozen_string_literal: true

require "test_helper"

# A note follows the key of its change's subject: a person's key in the plan
# when the subject is a person, the plan's key otherwise. So forgetting the
# person takes their notes with the rest, and deleting the plan takes every note.
class TeamPlanning::ChangeNoteTest < ActiveSupport::TestCase
  class CapacitySet < TeamPlanning::Events::Change
    extend Shreddable
    extend TeamPlanning::Events::SealedChange

    shreddable :fte, by: :person, person: :subject_id

    def self.facet = "capacity"
  end

  class HeadcountCap < TeamPlanning::RuleKind
    def self.rule_name = "test_headcount_cap"
    def self.description = "The most people a unit may hold"
    def self.default = { "cap" => 10 }
  end

  CAP = "rule:test_headcount_cap"
  PERSON_KINDS = %w[AssignmentSet DepartureSet DepartureWithdrawn LevelSet PlanDataSet ReportingLineSet].freeze

  setup do
    TeamPlanning::RuleKinds.register(HeadcountCap)
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @ada = create(:person, tenant: @tenant)
    @bo = create(:person, tenant: @tenant)
    editor = create(:person, tenant: @tenant)
    user = create(:user)
    actor = AuthorizationContext.new(user:, tenant_user: create(:tenant_user, tenant: @tenant, user:, person: editor, role: :admin), person: editor)
    @plan_id = SecureRandom.uuid_v7
    @handler = TeamPlanning::CommandHandler.new(actor:)
    @handler.create_plan(@plan_id, name: "Next year", base_on: "2026-11-14")
    @handler.set_change(@plan_id, TeamPlanning::Events::LevelSet, scenario_id: @plan_id, subject_id: @ada.id,
                                                                  end_state: { level: "4" }, note: "Ready since the platform launch")
    @handler.set_change(@plan_id, TeamPlanning::Events::RuleSet, scenario_id: @plan_id, subject_id: @plan_id,
                                                                 end_state: { rule: "test_headcount_cap", value: { cap: 8 } }, note: "Room for two hires")
  end

  teardown do
    ActsAsTenant.current_tenant = nil
    TeamPlanning::RuleKinds.unregister(HeadcountCap)
  end

  def events = Rails.configuration.event_store.read.stream(EventStreamNaming.plan_stream(@plan_id)).to_a

  def level_set = events.grep(TeamPlanning::Events::LevelSet).sole

  def rule_set = events.grep(TeamPlanning::Events::RuleSet).sole

  def identifier_of(event)
    sql = ActiveRecord::Base.sanitize_sql_array([ "SELECT convert_from(metadata, 'UTF8') FROM event_store_events WHERE event_id = ?", event.event_id ])
    JSON.parse(ActiveRecord::Base.connection.select_value(sql)).dig("shreddable", "note", "identifier")
  end

  def pinned(facet) = events.grep(TeamPlanning::Events::ChangePinned).find { it.data[:facet] == facet }

  def noted(change) = events.grep(TeamPlanning::Events::ChangeNoted).find { it.data[:noted_event_id] == change.event_id }

  def override_note(scenario_id, facet) = TeamPlanningOverride.find_by!(scenario_id:, facet:).note

  def plan_key = PlanKeyStore.plan_identifier(@tenant.id, @plan_id)

  def person_key(person) = PlanKeyStore.person_identifier(@tenant.id, @plan_id, person.id)

  should "read back both the level and the note" do
    assert_equal [ "4", "Ready since the platform launch" ], level_set.data.values_at(:level, :note).map(&:reveal)
  end

  should "seal the note on a person's change under their key in the plan, and on a rule under the plan's" do
    assert_equal person_key(@ada), identifier_of(level_set)
    assert_equal plan_key, identifier_of(rule_set)
  end

  should "remove both the level and the note once the person is forgotten, and keep the rule's note" do
    PlanKeyStore.new.destroy_person(@ada.id)

    assert level_set.data[:level].removed?
    assert level_set.data[:note].removed?
    assert_equal "Room for two hires", rule_set.data[:note].reveal
  end

  should "remove the rule's note with the plan's key alone, and keep the person's under their key" do
    PlanKeyStore.new.forget(plan_key)

    assert rule_set.data[:note].removed?
    assert_equal "Ready since the platform launch", level_set.data[:note].reveal
  end

  should "remove every note once the plan is deleted" do
    PlanKeyStore.new.destroy_plan(@plan_id)

    assert level_set.data[:note].removed?
    assert rule_set.data[:note].removed?
  end

  context "a pin and a rewritten note" do
    setup do
      @handler.set_change(@plan_id, TeamPlanning::Events::ReportingLineSet, scenario_id: @plan_id, subject_id: @bo.id,
                                                                            end_state: { manager_id: @ada.id })
      @child = SecureRandom.uuid_v7
      @handler.fork_scenario(@plan_id, @child, parent_id: @plan_id, relation: "then", name: "Q1", ends_on: "2027-03-31")
      @handler.pin_change(@plan_id, scenario_id: @child, subject_id: @bo.id, facet: "reporting_line", note: "Keep Bo with Ada")
      @handler.pin_change(@plan_id, scenario_id: @child, subject_id: @plan_id, facet: CAP, note: "Keep the cap")
      @handler.note_change(@plan_id, scenario_id: @plan_id, event_id: level_set.event_id, note: "Asked for it")
      @handler.note_change(@plan_id, scenario_id: @plan_id, event_id: rule_set.event_id, note: "Budget agreed")
    end

    should "seal under the person's key on a person's change, and under the plan's on a rule" do
      assert_equal person_key(@bo), identifier_of(pinned("reporting_line"))
      assert_equal plan_key, identifier_of(pinned(CAP))
      assert_equal person_key(@ada), identifier_of(noted(level_set))
      assert_equal plan_key, identifier_of(noted(rule_set))
    end

    should "remove the overrides' notes on the people forgotten, and keep the rules'" do
      [ @ada, @bo ].each { PlanKeyStore.new.destroy_person(it.id) }

      assert override_note(@child, "reporting_line").removed?
      assert override_note(@plan_id, "level").removed?
      assert_equal [ "Keep the cap", "Budget agreed" ], [ @child, @plan_id ].map { override_note(it, CAP).reveal }
    end
  end

  should "keep the note out of the end state a sealed change compares" do
    end_state = level_set.data.except(*TeamPlanning::Events::Change::FIELDS)

    assert_equal [ :level ], end_state.keys
    assert TeamPlanning::Events::LevelSet.same_end_state?(end_state, { level: Shreddable::Value.wrap("4") })
  end

  should "give a new sealed kind the note with nothing declared, under the plan's key" do
    assert_equal({ note: :plan, fte: :person }, CapacitySet.shreddable_fields.transform_values { it[:by] })
    assert CapacitySet.seals_end_state?
    assert_not TeamPlanning::Events::DepartureSet.seals_end_state?
  end

  should "count a subject a person only for the kinds that say so, alike across kinds that share a facet" do
    kinds = TeamPlanning::ChangeKinds.all

    assert_equal PERSON_KINDS, kinds.select(&:about_a_person?).map { it.name.demodulize }
    kinds.group_by(&:facet).each_value { assert_equal 1, it.map(&:about_a_person?).uniq.size, it.map(&:name).join(", ") }
  end
end
