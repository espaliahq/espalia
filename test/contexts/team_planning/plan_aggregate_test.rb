# frozen_string_literal: true

require "test_helper"

class TeamPlanning::PlanAggregateTest < ActiveSupport::TestCase
  setup do
    @plan_id = SecureRandom.uuid_v7
    @creator_id = SecureRandom.uuid_v7
    @plan = TeamPlanning::PlanAggregate.new
  end

  def create_plan(name: "Next year", base_on: "2026-11-14")
    @plan.create(@plan_id, name:, base_on:, created_by_id: @creator_id, time_zone: "UTC")
  end

  context "#create" do
    should "open the plan on its base date" do
      create_plan(name: "  Next   year ", base_on: Date.new(2026, 11, 14))

      event = @plan.unpublished_events.sole
      assert_kind_of TeamPlanning::Events::PlanCreated, event
      assert_equal({ plan_id: @plan_id, name: Shreddable::Value.new("Next year"), base_on: "2026-11-14", created_by_id: @creator_id, time_zone: "UTC" }, event.data)
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
      %w[soon friday 1 2026-W46 2026-318 2026-11-14x 2026-02-30].each do |base_on|
        assert_raises(Date::Error, base_on) { create_plan(base_on:) }
      end
    end
  end

  context "#set_scope" do
    setup { create_plan }

    should "cover the whole organisation until a scope is set" do
      assert_nil @plan.scope_unit_ids
    end

    should "record the units, sorted and downcased, once" do
      units = Array.new(2) { SecureRandom.uuid_v7 }
      @plan.set_scope(unit_ids: [ units.last.upcase, units.first, units.first ], set_by_id: @creator_id)
      @plan.set_scope(unit_ids: units.reverse, set_by_id: @creator_id)

      event = @plan.unpublished_events.to_a.last
      assert_kind_of TeamPlanning::Events::PlanScopeSet, event
      assert_equal({ plan_id: @plan_id, unit_ids: units.sort, set_by_id: @creator_id }, event.data)
      assert_equal 2, @plan.unpublished_events.count
      assert_equal units.sort, @plan.scope_unit_ids
    end

    should "widen to the whole organisation with no units, and write nothing for the whole organisation again" do
      @plan.set_scope(unit_ids: [ SecureRandom.uuid_v7 ], set_by_id: @creator_id)
      @plan.set_scope(unit_ids: [], set_by_id: @creator_id)
      @plan.set_scope(unit_ids: [], set_by_id: @creator_id)

      assert_nil @plan.scope_unit_ids
      assert_equal 3, @plan.unpublished_events.count
    end

    should "refuse a deleted plan" do
      @plan.delete(deleted_by_id: @creator_id)
      assert_raises(TeamPlanning::Error) { @plan.set_scope(unit_ids: [], set_by_id: @creator_id) }
    end
  end

  context "#rename" do
    setup { create_plan }

    should "record the new name and the one it replaces" do
      @plan.rename("Two-year plan", current: "Next year", renamed_by_id: @creator_id)

      event = @plan.unpublished_events.to_a.last
      assert_kind_of TeamPlanning::Events::PlanRenamed, event
      assert_equal "Next year", event.data[:previous_name].reveal
      assert_equal "Two-year plan", event.data[:name].reveal
    end

    should "write nothing for the same name" do
      @plan.rename(" Next year ", current: "Next year", renamed_by_id: @creator_id)
      assert_equal 1, @plan.unpublished_events.count
    end

    should "refuse once the plan is deleted" do
      @plan.delete(deleted_by_id: @creator_id)
      error = assert_raises(TeamPlanning::Error) { @plan.rename("Again", current: "Next year", renamed_by_id: @creator_id) }
      assert_equal "This plan has been deleted", error.message
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

  context "members" do
    setup do
      create_plan
      @other_id = SecureRandom.uuid_v7
    end

    should "make the creator the first editor" do
      assert_equal({ @creator_id => "editor" }, @plan.members)
      assert_equal [ @creator_id ], @plan.editor_ids
    end

    should "add a viewer, then change their role, and write nothing for the same role" do
      @plan.add_member(@other_id, role: "viewer", added_by_id: @creator_id)
      @plan.add_member(@other_id, role: "viewer", added_by_id: @creator_id)
      @plan.add_member(@other_id, role: "editor", added_by_id: @creator_id)

      added = @plan.unpublished_events.grep(TeamPlanning::Events::PlanMemberAdded)
      assert_equal %w[viewer editor], added.map { it.data[:role] }
      assert_equal({ plan_id: @plan_id, person_id: @other_id, role: "editor", added_by_id: @creator_id }, added.last.data)
      assert_equal "editor", @plan.role_of(@other_id)
    end

    should "refuse a role it doesn't know" do
      error = assert_raises(TeamPlanning::Error) { @plan.add_member(@other_id, role: "owner", added_by_id: @creator_id) }
      assert_equal "A member is an editor or a viewer", error.message
    end

    should "keep its last editor: they can neither leave nor become a viewer" do
      [ -> { @plan.remove_member(@creator_id, removed_by_id: @creator_id) },
        -> { @plan.add_member(@creator_id, role: "viewer", added_by_id: @creator_id) } ].each do |command|
        assert_match "A plan needs an editor", assert_raises(TeamPlanning::Error, &command).message
      end
      assert_equal "editor", @plan.role_of(@creator_id)
    end

    should "let an editor step down once there is another" do
      @plan.add_member(@other_id, role: "editor", added_by_id: @creator_id)
      @plan.grant_see_pay(@other_id, granted_by_id: @creator_id)
      @plan.remove_member(@creator_id, removed_by_id: @creator_id)

      assert_not @plan.member?(@creator_id)
      assert_equal [ @other_id ], @plan.editor_ids
      assert_equal({ plan_id: @plan_id, person_id: @creator_id, removed_by_id: @creator_id },
                   @plan.unpublished_events.to_a.last.data)
    end

    should "refuse to remove someone who isn't a member" do
      assert_raises(TeamPlanning::Error) { @plan.remove_member(@other_id, removed_by_id: @creator_id) }
    end

    should "take no members once deleted" do
      @plan.delete(deleted_by_id: @creator_id)
      assert_raises(TeamPlanning::Error) { @plan.add_member(@other_id, role: "viewer", added_by_id: @creator_id) }
    end
  end

  context "the see-pay right" do
    setup do
      create_plan
      @other_id = SecureRandom.uuid_v7
      @plan.add_member(@other_id, role: "viewer", added_by_id: @creator_id)
    end

    should "start with the creator alone" do
      assert @plan.sees_pay?(@creator_id)
      assert_not @plan.sees_pay?(@other_id)
      assert_equal [ @creator_id ], @plan.pay_holder_ids
    end

    should "grant it once, naming who did, and write nothing for a second grant" do
      @plan.grant_see_pay(@other_id, granted_by_id: @creator_id)
      @plan.grant_see_pay(@other_id, granted_by_id: @creator_id)

      granted = @plan.unpublished_events.grep(TeamPlanning::Events::SeePayGranted)
      assert_equal [ { plan_id: @plan_id, person_id: @other_id, granted_by_id: @creator_id } ], granted.map(&:data)
      assert @plan.sees_pay?(@other_id)
    end

    should "mark a grant made in recovery" do
      @plan.grant_see_pay(@other_id, granted_by_id: SecureRandom.uuid_v7, recovery: true)
      assert @plan.unpublished_events.to_a.last.data[:recovery]
    end

    should "refuse someone who isn't a member" do
      error = assert_raises(TeamPlanning::Error) { @plan.grant_see_pay(SecureRandom.uuid_v7, granted_by_id: @creator_id) }
      assert_equal "They aren't a member of this plan", error.message
    end

    should "withdraw it, and write nothing from someone who doesn't hold it" do
      @plan.withdraw_see_pay(@other_id, withdrawn_by_id: @creator_id)
      @plan.grant_see_pay(@other_id, granted_by_id: @creator_id)
      @plan.withdraw_see_pay(@other_id, withdrawn_by_id: @creator_id)

      withdrawn = @plan.unpublished_events.grep(TeamPlanning::Events::SeePayWithdrawn)
      assert_equal [ { plan_id: @plan_id, person_id: @other_id, withdrawn_by_id: @creator_id } ], withdrawn.map(&:data)
      assert_not @plan.sees_pay?(@other_id)
    end

    should "keep its last holder: they can neither give it up nor leave" do
      @plan.add_member(@other_id, role: "editor", added_by_id: @creator_id)
      [ -> { @plan.withdraw_see_pay(@creator_id, withdrawn_by_id: @creator_id) },
        -> { @plan.remove_member(@creator_id, removed_by_id: @creator_id) } ].each do |command|
        assert_match "A plan needs someone who can see pay", assert_raises(TeamPlanning::Error, &command).message
      end
      assert @plan.sees_pay?(@creator_id)
    end

    should "let a holder go once another holds it" do
      @plan.grant_see_pay(@other_id, granted_by_id: @creator_id)
      @plan.withdraw_see_pay(@creator_id, withdrawn_by_id: @creator_id)
      assert_equal [ @other_id ], @plan.pay_holder_ids
    end

    should "lose it with membership, and not get it back on rejoining" do
      second_id = SecureRandom.uuid_v7
      @plan.add_member(second_id, role: "viewer", added_by_id: @creator_id)
      @plan.grant_see_pay(second_id, granted_by_id: @creator_id)
      @plan.remove_member(second_id, removed_by_id: @creator_id)
      @plan.add_member(second_id, role: "viewer", added_by_id: @creator_id)

      assert_not @plan.sees_pay?(second_id)
    end

    should "replay the same holders from the stream" do
      @plan.grant_see_pay(@other_id, granted_by_id: @creator_id)
      replayed = TeamPlanning::PlanAggregate.new
      @plan.unpublished_events.each { replayed.apply(it) }
      assert_equal @plan.pay_holder_ids.sort, replayed.pay_holder_ids.sort
    end

    should "take no grants once deleted" do
      @plan.delete(deleted_by_id: @creator_id)
      assert_raises(TeamPlanning::Error) { @plan.grant_see_pay(@other_id, granted_by_id: @creator_id) }
    end
  end

  context "archiving" do
    setup do
      create_plan
      @other_id = SecureRandom.uuid_v7
      @plan.add_member(@other_id, role: "editor", added_by_id: @creator_id)
      @plan.fork_scenario(@scenario_id = SecureRandom.uuid_v7, parent_id: @plan_id, relation: "then", name: "Q1",
                          ends_on: "2027-03-31", forked_by_id: @creator_id)
      @plan.set_change(TeamPlanning::Events::LevelSet, scenario_id: @scenario_id, subject_id: @other_id,
                       set_by_id: @creator_id, end_state: { level: "E5" })
      @plan.archive(archived_by_id: @creator_id, archived_on: Date.new(2026, 11, 16), time_zone: "UTC")
    end

    should "record who archived it, and refuse a second archive" do
      assert_equal({ plan_id: @plan_id, archived_by_id: @creator_id, archived_on: "2026-11-16", time_zone: "UTC" }, @plan.unpublished_events.to_a.last.data)
      assert @plan.archived?
      assert_equal "This plan is already archived", assert_raises(TeamPlanning::Error) { @plan.archive(archived_by_id: @creator_id, archived_on: Date.new(2026, 11, 16), time_zone: "UTC") }.message
    end

    should "copy the prices only for an archive it records" do
      asked = 0
      assert_raises(TeamPlanning::Error) { @plan.archive(archived_by_id: @creator_id, archived_on: Date.new(2026, 11, 16), time_zone: "UTC", prices: -> { asked += 1 }) }
      assert_equal 0, asked

      @plan.restore(restored_by_id: @creator_id)
      @plan.archive(archived_by_id: @creator_id, archived_on: Date.new(2026, 11, 16), time_zone: "UTC", prices: -> { { "pay_bands" => [] } })
      assert_equal [ TeamPlanning::Events::PlanArchived, TeamPlanning::Events::PlanPricesFrozen ], @plan.unpublished_events.to_a.last(2).map(&:class)
    end

    should "refuse every change to what the plan holds, in one message" do
      writes = [
        -> { @plan.set_scope(unit_ids: [ SecureRandom.uuid_v7 ], set_by_id: @creator_id) },
        -> { @plan.rename("Later", current: "Next year", renamed_by_id: @creator_id) },
        -> { @plan.rebase(base_on: "2026-12-01", expected_base_on: "2026-11-14", conflicts: [], rebased_by_id: @creator_id, time_zone: "UTC") },
        -> { @plan.add_member(SecureRandom.uuid_v7, role: "viewer", added_by_id: @creator_id) },
        -> { @plan.remove_member(@other_id, removed_by_id: @creator_id) },
        -> { @plan.grant_see_pay(@other_id, granted_by_id: @creator_id) },
        -> { @plan.withdraw_see_pay(@creator_id, withdrawn_by_id: @creator_id) },
        -> { @plan.fork_scenario(SecureRandom.uuid_v7, parent_id: @plan_id, relation: "instead", name: "B", forked_by_id: @creator_id) },
        -> { @plan.rename_scenario(@scenario_id, name: "Q2", current: "Q1", renamed_by_id: @creator_id) },
        -> { @plan.set_scenario_period(@scenario_id, ends_on: "2027-06-30", set_by_id: @creator_id) },
        -> { @plan.remove_scenario(@scenario_id, removed_by_id: @creator_id) },
        -> { @plan.set_change(TeamPlanning::Events::LevelSet, scenario_id: @scenario_id, subject_id: @creator_id, set_by_id: @creator_id, end_state: { level: "E6" }) },
        -> { @plan.clear_change(scenario_id: @scenario_id, subject_id: @other_id, facet: "level", cleared_by_id: @creator_id) },
        -> { @plan.undo_change(scenario_id: @scenario_id, event_id: @plan.changes_in(@scenario_id).last.event_id, undone_by_id: @creator_id) }
      ]
      before = @plan.unpublished_events.count

      writes.each do |write|
        assert_equal TeamPlanning::PlanAggregate::ARCHIVED, assert_raises(TeamPlanning::Error, &write).message
      end
      assert_equal before, @plan.unpublished_events.count
    end

    should "let a member leave, take off one who departed, and still be deleted" do
      @plan.remove_member(@other_id, removed_by_id: @other_id)
      viewer = SecureRandom.uuid_v7
      @plan.restore(restored_by_id: @creator_id)
      @plan.add_member(viewer, role: "viewer", added_by_id: @creator_id)
      @plan.archive(archived_by_id: @creator_id, archived_on: Date.new(2026, 11, 16), time_zone: "UTC")
      @plan.remove_member(viewer, removed_by_id: @creator_id, departed: true)
      @plan.delete(deleted_by_id: @creator_id)

      assert_equal({ @creator_id => "editor" }, @plan.members)
      assert @plan.deleted?
    end

    should "keep its last editor and its last pay holder while archived" do
      leave = -> { @plan.remove_member(@creator_id, removed_by_id: @creator_id) }
      assert_match "A plan needs someone who can see pay", assert_raises(TeamPlanning::Error, &leave).message

      @plan.remove_member(@other_id, removed_by_id: @other_id)
      assert_match "A plan needs an editor", assert_raises(TeamPlanning::Error, &leave).message
    end

    should "let a tenant admin restore see-pay to a locked-out plan" do
      @plan.grant_see_pay(@other_id, granted_by_id: SecureRandom.uuid_v7, recovery: true)
      assert @plan.sees_pay?(@other_id)
    end

    should "restore exactly as archived, and take changes again" do
      changes = @plan.winning_changes(@scenario_id)
      @plan.restore(restored_by_id: @other_id)

      assert_equal({ plan_id: @plan_id, restored_by_id: @other_id }, @plan.unpublished_events.to_a.last.data)
      assert_not @plan.archived?
      assert_equal changes, @plan.winning_changes(@scenario_id)
      @plan.rename("Later", current: "Next year", renamed_by_id: @creator_id)
      assert_equal "This plan isn't archived", assert_raises(TeamPlanning::Error) { @plan.restore(restored_by_id: @creator_id) }.message
    end

    should "replay archived, then live again" do
      replayed = TeamPlanning::PlanAggregate.new
      @plan.unpublished_events.each { replayed.apply(it) }
      assert replayed.archived?

      replayed.restore(restored_by_id: @creator_id)
      assert_not replayed.archived?
    end
  end

  context "#delete with a reason" do
    should "keep the reason, and leave it out when there is none" do
      create_plan
      @plan.delete(deleted_by_id: @creator_id, reason: " Its editor left ")
      assert_equal "Its editor left", @plan.unpublished_events.to_a.last.data[:reason]

      other = TeamPlanning::PlanAggregate.new
      other.create(SecureRandom.uuid_v7, name: "Other", base_on: "2026-11-14", created_by_id: @creator_id, time_zone: "UTC")
      other.delete(deleted_by_id: @creator_id)
      assert_not other.unpublished_events.to_a.last.data.key?(:reason)
    end
  end
end
