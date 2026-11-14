# frozen_string_literal: true

require "test_helper"

class TeamPlanning::PlanAggregateTest < ActiveSupport::TestCase
  setup do
    @plan_id = SecureRandom.uuid_v7
    @creator_id = SecureRandom.uuid_v7
    @plan = TeamPlanning::PlanAggregate.new
  end

  def create_plan(name: "Next year", base_on: "2026-11-14")
    @plan.create(@plan_id, name:, base_on:, created_by_id: @creator_id)
  end

  context "#create" do
    should "open the plan on its base date" do
      create_plan(name: "  Next   year ", base_on: Date.new(2026, 11, 14))

      event = @plan.unpublished_events.sole
      assert_kind_of TeamPlanning::Events::PlanCreated, event
      assert_equal({ plan_id: @plan_id, name: "Next year", base_on: "2026-11-14", created_by_id: @creator_id }, event.data)
      assert_equal Date.new(2026, 11, 14), @plan.base_on
      assert_equal @creator_id, @plan.created_by_id
    end

    should "refuse a second create" do
      create_plan
      error = assert_raises(TeamPlanning::Error) { create_plan }
      assert_equal "This plan already exists", error.message
    end

    should "refuse a blank or overlong name" do
      assert_raises(TeamPlanning::Error) { create_plan(name: "  ") }
      assert_raises(TeamPlanning::Error) { create_plan(name: "x" * 121) }
      assert_empty @plan.unpublished_events.to_a
    end

    should "refuse a base that is not a date" do
      assert_raises(ArgumentError) { create_plan(base_on: "soon") }
    end
  end

  context "#rename" do
    setup { create_plan }

    should "record the new name and the one it replaces" do
      @plan.rename("Two-year plan", renamed_by_id: @creator_id)

      event = @plan.unpublished_events.to_a.last
      assert_kind_of TeamPlanning::Events::PlanRenamed, event
      assert_equal "Next year", event.data[:previous_name]
      assert_equal "Two-year plan", @plan.name
    end

    should "write nothing for the same name" do
      @plan.rename(" Next year ", renamed_by_id: @creator_id)
      assert_equal 1, @plan.unpublished_events.count
    end

    should "refuse once the plan is deleted" do
      @plan.delete(deleted_by_id: @creator_id)
      error = assert_raises(TeamPlanning::Error) { @plan.rename("Again", renamed_by_id: @creator_id) }
      assert_equal "Next year has been deleted", error.message
    end
  end

  context "#delete" do
    should "refuse a plan that was never created" do
      assert_raises(TeamPlanning::Error) { @plan.delete(deleted_by_id: @creator_id) }
    end

    should "refuse a second delete" do
      create_plan
      @plan.delete(deleted_by_id: @creator_id)
      assert @plan.deleted?
      assert_raises(TeamPlanning::Error) { @plan.delete(deleted_by_id: @creator_id) }
    end
  end
end
