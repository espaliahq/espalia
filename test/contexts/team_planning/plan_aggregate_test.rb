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
      assert_equal({ plan_id: @plan_id, name: Shreddable::Value.new("Next year"), base_on: "2026-11-14", created_by_id: @creator_id }, event.data)
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

  context "#delete with a reason" do
    should "keep the reason, and leave it out when there is none" do
      create_plan
      @plan.delete(deleted_by_id: @creator_id, reason: " Its editor left ")
      assert_equal "Its editor left", @plan.unpublished_events.to_a.last.data[:reason]

      other = TeamPlanning::PlanAggregate.new
      other.create(SecureRandom.uuid_v7, name: "Other", base_on: "2026-11-14", created_by_id: @creator_id)
      other.delete(deleted_by_id: @creator_id)
      assert_not other.unpublished_events.to_a.last.data.key?(:reason)
    end
  end
end
