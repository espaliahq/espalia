# frozen_string_literal: true

require "test_helper"

class TeamPlanning::PlanAggregateChangesTest < ActiveSupport::TestCase
  class TitleSet < TeamPlanning::Events::Change
    def self.facet = "title"
    def self.end_state(end_state) = end_state.tap { raise TeamPlanning::Error, "A title can't be blank" if it[:title].blank? }
    def self.apply_to(map, _data) = map
  end

  class Filtering < TeamPlanning::Events::Change
    def self.facet = "title"
    def self.end_state(end_state) = end_state.slice(:title)
    def self.apply_to(map, _data) = map
  end

  class Unfinished < TeamPlanning::Events::Change
    def self.facet = "title"
  end

  setup do
    @plan_id = SecureRandom.uuid_v7
    @editor_id = SecureRandom.uuid_v7
    @plan = TeamPlanning::PlanAggregate.new
    @plan.create(@plan_id, name: "Next year", base_on: "2027-01-01", created_by_id: @editor_id)
    @q1 = fork(@plan_id, "then", ends_on: "2027-03-31")
    @lean = fork(@q1, "instead")
    @q2 = fork(@q1, "then", ends_on: "2027-06-30")
    @lean_q2 = fork(@lean, "then", ends_on: "2027-06-30")
  end

  def fork(parent_id, relation, ends_on: nil)
    SecureRandom.uuid_v7.tap do
      @plan.fork_scenario(it, parent_id:, relation:, name: "S", ends_on:, forked_by_id: @editor_id)
    end
  end

  def set(scenario_id, title, subject_id: "ada") = @plan.set_change(TitleSet, scenario_id:, subject_id:, set_by_id: @editor_id, end_state: { title: })

  def refusal(&) = assert_raises(TeamPlanning::Error, &).message

  should "resolve an alternative through its parent, and lay it out in its parent's place" do
    assert_equal [ @plan_id, @q1, @lean, @lean_q2 ], @plan.resolution_chain(@lean_q2)
    assert_equal [ @plan_id, @lean, @lean_q2 ], @plan.timeline_path(@lean_q2)
    assert_equal [ @plan_id, @q1, @q2 ], @plan.resolution_chain(@q2)
    assert_equal [ @plan_id, @q1, @q2 ], @plan.timeline_path(@q2)
    assert_equal [ @plan_id ], @plan.resolution_chain(@plan_id)
  end

  should "record a change in its scenario, in order, naming who made it" do
    set(@q1, "Senior Engineer")
    set(@q1, "Lead Engineer")

    assert_equal({ plan_id: @plan_id, scenario_id: @q1, subject_id: "ada", title: "Lead Engineer", set_by_id: @editor_id },
                 @plan.unpublished_events.to_a.last.data)
    assert_equal [ "Senior Engineer", "Lead Engineer" ], @plan.changes_in(@q1).map { it.data[:title] }
    assert_empty @plan.changes_in(@q2)
    assert_equal [ [ "ada", "title" ] ], @plan.changes_in(@q1).map(&:key).uniq
  end

  should "refuse an unknown scenario, an end state the kind refuses, anything not a whole change, and a deleted plan" do
    assert_equal "This plan has no such scenario", refusal { set(SecureRandom.uuid_v7, "Senior Engineer") }
    assert_equal "A title can't be blank", refusal { set(@q1, " ") }
    assert_raises(ArgumentError) do
      @plan.set_change(TeamPlanning::Events::ScenarioRemoved, scenario_id: @q1, subject_id: "ada", set_by_id: @editor_id)
    end

    assert_raises(ArgumentError) do
      @plan.set_change(Unfinished, scenario_id: @q1, subject_id: "ada", set_by_id: @editor_id, end_state: { title: "Lead" })
    end
    taken = assert_raises(ArgumentError) do
      @plan.set_change(TitleSet, scenario_id: @q1, subject_id: "ada", set_by_id: @editor_id,
                                 end_state: { title: "Lead", "set_by_id" => "someone else", plan_id: "another" })
    end
    assert_equal "An end state can't set set_by_id, plan_id", taken.message
    assert_raises(ArgumentError, "a kind that drops unknown fields must not hide a reserved one") do
      @plan.set_change(Filtering, scenario_id: @q1, subject_id: "ada", set_by_id: @editor_id, end_state: { title: "Lead", plan_id: "another" })
    end

    @plan.delete(deleted_by_id: @editor_id)
    assert_equal "Next year has been deleted", refusal { set(@q1, "Senior Engineer") }
  end

  should "forget a removed scenario's changes, and rebuild the rest from the events" do
    set(@q1, "Senior Engineer")
    set(@lean_q2, "Staff Engineer")
    @plan.remove_scenario(@lean_q2, removed_by_id: @editor_id)

    replayed = TeamPlanning::PlanAggregate.new
    @plan.unpublished_events.each { replayed.apply(it) }

    assert_empty replayed.changes_in(@lean_q2)
    assert_equal @plan.changes_in(@q1).map(&:data), replayed.changes_in(@q1).map(&:data)
  end
end
