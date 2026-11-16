# frozen_string_literal: true

require "test_helper"

class TeamPlanning::CommandHandlerTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @admin = context_for(create(:person, tenant: @tenant), role: :admin)
    @plan_id = SecureRandom.uuid_v7
  end

  teardown { ActsAsTenant.current_tenant = nil }

  should "refuse to build without an actor" do
    assert_raises(ArgumentError) { TeamPlanning::CommandHandler.new }
    assert_raises(ArgumentError) { TeamPlanning::CommandHandler.new(actor: nil) }
    assert_raises(ArgumentError) { TeamPlanning::CommandHandler.new(actor: create(:person, tenant: @tenant)) }
  end

  should "follow an unknown allocation and a cleared level, and refuse any other value the Org Graph holds that no change can" do
    followable = ->(kind, end_state) { handler(@admin).send(:followable, kind, end_state) }
    unit_id = SecureRandom.uuid_v7

    assert followable.call(TeamPlanning::Events::AssignmentSet, { placements: [ { unit_id:, allocation: nil } ] })
    assert followable.call(TeamPlanning::Events::LevelSet, { level: nil })
    refusal = assert_raises(TeamPlanning::Error) do
      followable.call(TeamPlanning::Events::AssignmentSet, { placements: [ { unit_id:, allocation: 2 } ] })
    end
    assert_equal "The Org Graph holds a value this plan can't hold yet, so this can't follow reality. You can still keep the plan", refusal.message
  end

  context "#create_plan" do
    should "write the plan to its own stream, with the tenant and its creator" do
      handler(@admin).create_plan(@plan_id, name: "Next year", base_on: "2026-11-14")

      event = event_store.read.stream(EventStreamNaming.plan_stream(@plan_id)).to_a.sole
      assert_kind_of TeamPlanning::Events::PlanCreated, event
      assert_equal @tenant.id, event.metadata[:tenant_id]
      assert_equal @admin.person.id, event.data[:created_by_id]
    end

    should "refuse a member who is neither a tenant admin nor a planner" do
      member = context_for(create(:person, tenant: @tenant))
      error = assert_raises(Pundit::NotAuthorizedError) { handler(member).create_plan(@plan_id, name: "Mine", base_on: "2026-11-14") }
      assert_equal "Only a tenant admin or a planner can create a plan", error.message
    end

    should "let a planner create one" do
      planner = context_for(create(:person, tenant: @tenant), team_planner: true)
      assert handler(planner).create_plan(@plan_id, name: "Mine", base_on: "2026-11-14").exists?
    end

    should "refuse an admin with no person, since a plan names its creator" do
      user = create(:user)
      tenant_user = create(:tenant_user, tenant: @tenant, user:, role: :admin)
      unlinked = AuthorizationContext.new(user:, tenant_user:, person: nil)

      assert_raises(TeamPlanning::Error) { handler(unlinked).create_plan(@plan_id, name: "Mine", base_on: "2026-11-14") }
    end

    should "hold the stream's lock while it writes" do
      held = nil
      repository = TeamPlanning::Repository.new
      repository.define_singleton_method(:lock_stream) { |stream| held = stream; super(stream) }
      TeamPlanning::CommandHandler.new(actor: @admin, repository:).create_plan(@plan_id, name: "Next year", base_on: "2026-11-14")
      assert_equal EventStreamNaming.plan_stream(@plan_id), held
    end
  end

  context "members" do
    setup do
      handler(@admin).create_plan(@plan_id, name: "Next year", base_on: "2026-11-14")
      @colleague = create(:person, tenant: @tenant)
      create(:tenant_user, tenant: @tenant, person: @colleague)
    end

    should "let an editor add a viewer, who may then leave" do
      handler(@admin).add_member(@plan_id, @colleague.id, role: "viewer")
      handler(context_for(@colleague)).remove_member(@plan_id, @colleague.id)

      added, removed = event_store.read.stream(EventStreamNaming.plan_stream(@plan_id)).to_a.last(2)
      assert_equal "viewer", added.data[:role]
      assert_equal @admin.person.id, added.data[:added_by_id]
      assert_equal @colleague.id, removed.data[:removed_by_id]
    end

    should "refuse a viewer who tries to add or remove someone else, as a missing plan" do
      handler(@admin).add_member(@plan_id, @colleague.id, role: "viewer")
      viewer = handler(context_for(@colleague))
      third = create(:person, tenant: @tenant)
      [ -> { viewer.add_member(@plan_id, third.id, role: "viewer") }, -> { viewer.remove_member(@plan_id, @admin.person.id) },
        -> { viewer.rename_plan(@plan_id, "Mine now") } ].each do |command|
        assert_equal "No such plan", assert_raises(TeamPlanning::Error, &command).message
      end
    end

    should "admit only someone active and remembered" do
      gone = create(:person, tenant: @tenant, status: "inactive")
      error = assert_raises(TeamPlanning::Error) { handler(@admin).add_member(@plan_id, gone.id, role: "viewer") }
      assert_equal "Only someone active in this organisation, with an account here, can join a plan", error.message
      assert_raises(TeamPlanning::Error) { handler(@admin).add_member(@plan_id, SecureRandom.uuid_v7, role: "viewer") }
    end

    should "refuse someone with no account here, who could never open the plan" do
      stranger = create(:person, tenant: @tenant)
      error = assert_raises(TeamPlanning::Error) { handler(@admin).add_member(@plan_id, stranger.id, role: "editor") }
      assert_match "with an account here", error.message
    end

    should "not let the last editor leave the plan to an editor whose account has gone" do
      handler(@admin).add_member(@plan_id, @colleague.id, role: "editor")
      TenantUser.where(person: @colleague).update_all(forgotten_at: Time.current)

      error = assert_raises(TeamPlanning::Error) { handler(@admin).remove_member(@plan_id, @admin.person.id) }
      assert_match "A plan needs an editor", error.message
    end

    should "not let the last reachable editor hand the plan to an editor who has left" do
      handler(@admin).add_member(@plan_id, @colleague.id, role: "editor")
      @colleague.update!(status: "inactive")

      [ -> { handler(@admin).remove_member(@plan_id, @admin.person.id) },
        -> { handler(@admin).add_member(@plan_id, @admin.person.id, role: "viewer") } ].each do |command|
        assert_match "A plan needs an editor", assert_raises(TeamPlanning::Error, &command).message
      end
      handler(@admin).remove_member(@plan_id, @colleague.id)
    end

    should "let an editor step a co-editor who has left down to viewer, but not back up" do
      handler(@admin).add_member(@plan_id, @colleague.id, role: "editor")
      @colleague.update!(status: "inactive")

      assert_equal "viewer", handler(@admin).add_member(@plan_id, @colleague.id, role: "viewer").role_of(@colleague.id)
      assert_raises(TeamPlanning::Error) { handler(@admin).add_member(@plan_id, @colleague.id, role: "editor") }
    end
  end

  context "#delete_frozen_plan" do
    setup do
      @editor = create(:person, tenant: @tenant)
      handler(context_for(@editor, team_planner: true)).create_plan(@plan_id, name: "Next year", base_on: "2026-11-14")
    end

    should "read as missing while the plan has an editor" do
      error = assert_raises(TeamPlanning::Error) { handler(@admin).delete_frozen_plan(@plan_id, reason: "Tidying up") }
      assert_equal "No such plan", error.message
    end

    should "delete it once frozen, and keep who and why" do
      @editor.update!(status: "inactive")
      handler(@admin).delete_frozen_plan(@plan_id, reason: "Its only editor left")

      event = event_store.read.stream(EventStreamNaming.plan_stream(@plan_id)).to_a.last
      assert_kind_of TeamPlanning::Events::PlanDeleted, event
      assert_equal({ plan_id: @plan_id, deleted_by_id: @admin.person.id, reason: "Its only editor left" }, event.data)
    end

    should "need a reason, and a tenant admin" do
      @editor.update!(status: "inactive")
      assert_raises(TeamPlanning::Error) { handler(@admin).delete_frozen_plan(@plan_id, reason: " ") }
      member = context_for(create(:person, tenant: @tenant))
      assert_equal "No such plan", assert_raises(TeamPlanning::Error) { handler(member).delete_frozen_plan(@plan_id, reason: "Mine") }.message
    end
  end

  context "the see-pay right" do
    setup do
      @creator = create(:person, tenant: @tenant)
      @owner = context_for(@creator, team_planner: true)
      handler(@owner).create_plan(@plan_id, name: "Next year", base_on: "2026-11-14")
      @colleague = create(:person, tenant: @tenant)
      @colleague_context = context_for(@colleague)
      handler(@owner).add_member(@plan_id, @colleague.id, role: "editor")
    end

    should "let a holder grant it and take it back, naming themselves" do
      handler(@owner).grant_see_pay(@plan_id, @colleague.id)
      plan = handler(@owner).withdraw_see_pay(@plan_id, @colleague.id)

      granted, withdrawn = event_store.read.stream(EventStreamNaming.plan_stream(@plan_id)).to_a.last(2)
      assert_equal @creator.id, granted.data[:granted_by_id]
      assert_equal @creator.id, withdrawn.data[:withdrawn_by_id]
      assert_not plan.sees_pay?(@colleague.id)
    end

    should "refuse an editor who doesn't hold it, as a missing plan" do
      viewer = create(:person, tenant: @tenant)
      context_for(viewer)
      handler(@owner).add_member(@plan_id, viewer.id, role: "viewer")

      [ -> { handler(@colleague_context).grant_see_pay(@plan_id, @colleague.id) },
        -> { handler(@colleague_context).grant_see_pay(@plan_id, viewer.id) },
        -> { handler(@colleague_context).withdraw_see_pay(@plan_id, @creator.id) } ].each do |command|
        assert_equal "No such plan", assert_raises(TeamPlanning::Error, &command).message
      end
    end

    should "refuse to give it to a member who has left" do
      @colleague.update!(status: "inactive")
      error = assert_raises(TeamPlanning::Error) { handler(@owner).grant_see_pay(@plan_id, @colleague.id) }
      assert_match "still active", error.message
    end

    should "keep the last holder who can still open the plan, whoever else holds it" do
      other_editor = create(:person, tenant: @tenant)
      context_for(other_editor)
      handler(@owner).add_member(@plan_id, other_editor.id, role: "editor")
      handler(@owner).grant_see_pay(@plan_id, @colleague.id)
      @colleague.update!(status: "inactive")

      [ -> { handler(@owner).withdraw_see_pay(@plan_id, @creator.id) },
        -> { handler(@owner).remove_member(@plan_id, @creator.id) } ].each do |command|
        assert_match "A plan needs someone who can see pay", assert_raises(TeamPlanning::Error, &command).message
      end
    end

    context "a plan locked out of pay" do
      setup { @creator.update!(status: "inactive") }

      should "still let an editor take off the holder who left" do
        plan = handler(@colleague_context).remove_member(@plan_id, @creator.id)

        assert_not plan.member?(@creator.id)
        assert_empty plan.pay_holder_ids
        assert PlanPolicy.locked_out?(ActsAsTenant.with_tenant(@tenant) { TeamPlanningPlan.find(@plan_id) })
      end

      should "be restored by a tenant admin to its reachable editors, each grant the admin's" do
        result = handler(@admin).restore_see_pay(@plan_id)

        assert result.sees_pay?(@colleague.id)
        event = event_store.read.stream(EventStreamNaming.plan_stream(@plan_id)).to_a.last
        assert_kind_of TeamPlanning::Events::SeePayGranted, event
        assert_equal({ plan_id: @plan_id, person_id: @colleague.id, granted_by_id: @admin.person.id, recovery: true }, event.data)
      end

      should "let a holder restored that way withdraw it from the others" do
        third = create(:person, tenant: @tenant)
        context_for(third)
        handler(@colleague_context).add_member(@plan_id, third.id, role: "editor")
        handler(@admin).restore_see_pay(@plan_id)

        assert_not handler(@colleague_context).withdraw_see_pay(@plan_id, third.id).sees_pay?(third.id)
      end

      should "refuse anyone but a tenant admin, in the same words" do
        error = assert_raises(TeamPlanning::Error) { handler(@colleague_context).restore_see_pay(@plan_id) }
        assert_equal "No such plan", error.message
      end

      should "refuse a frozen plan, which has no editor to restore it to" do
        @colleague.update!(status: "inactive")
        error = assert_raises(TeamPlanning::Error) { handler(@admin).restore_see_pay(@plan_id) }
        assert_equal "No such plan", error.message
      end
    end

    should "refuse a plan that isn't locked out exactly as one that doesn't exist, or was deleted" do
      gone = SecureRandom.uuid_v7
      handler(@owner).create_plan(gone, name: "Gone", base_on: "2026-11-14")
      @creator.update!(status: "inactive")
      handler(@admin).delete_frozen_plan(gone, reason: "Its editor left")
      @creator.update!(status: "active")

      refusals = [ @plan_id, SecureRandom.uuid_v7, gone ].map do |plan_id|
        assert_raises(TeamPlanning::Error) { handler(@admin).restore_see_pay(plan_id) }.message
      end
      assert_equal [ "No such plan" ] * 3, refusals
    end
  end

  context "a deleted plan's keys" do
    setup do
      handler(@admin).create_plan(@plan_id, name: "Next year", base_on: "2026-11-14")
      @plan_key = PlanKeyStore.plan_identifier(@tenant.id, @plan_id)
      @person_key = PlanKeyStore.person_identifier(@tenant.id, @plan_id, @admin.person.id)
      @other_plan_key = PlanKeyStore.plan_identifier(@tenant.id, SecureRandom.uuid_v7)
      [ @plan_key, @person_key, @other_plan_key ].each { key_store.create(it) }
    end

    should "be destroyed with the plan, and no new one minted" do
      handler(@admin).delete_plan(@plan_id)

      assert_nil key_store.key_of(@plan_key)
      assert_nil key_store.key_of(@person_key)
      assert_raises(PlanKeyStore::Destroyed) { key_store.create(@plan_key) }
      assert_raises(PlanKeyStore::Destroyed) { key_store.create(@person_key) }
      assert key_store.key_of(@other_plan_key)
    end

    should "be destroyed when a tenant admin deletes the plan frozen" do
      @admin.person.update!(status: "inactive")
      other_admin = context_for(create(:person, tenant: @tenant), role: :admin)

      handler(other_admin).delete_frozen_plan(@plan_id, reason: "Its only editor left")

      assert_nil key_store.key_of(@plan_key)
      assert_nil key_store.key_of(@person_key)
    end

    should "survive a delete that is refused" do
      outsider = context_for(create(:person, tenant: @tenant), role: :admin)
      assert_raises(TeamPlanning::Error) { handler(outsider).delete_plan(@plan_id) }

      assert key_store.key_of(@plan_key)
      assert key_store.key_of(@person_key)
    end

    should "leave no PlanDeleted when destroying them fails, since both share one transaction" do
      failing = Object.new.tap { it.define_singleton_method(:destroy_plan) { |_| raise PlanKeyStore::Unavailable } }

      assert_raises(PlanKeyStore::Unavailable) do
        PlanKeyStore.stub(:new, failing) do
          ActiveRecord::Base.transaction(requires_new: true) { handler(@admin).delete_plan(@plan_id) }
        end
      end

      assert_equal [ TeamPlanning::Events::PlanCreated ],
                   event_store.read.stream(EventStreamNaming.plan_stream(@plan_id)).map(&:class)
    end
  end

  context "an archived plan" do
    setup do
      @editor = create(:person, tenant: @tenant)
      @owner = context_for(@editor, team_planner: true)
      handler(@owner).create_plan(@plan_id, name: "Next year", base_on: "2026-11-14")
      @colleague = create(:person, tenant: @tenant)
      @colleague_context = context_for(@colleague)
      handler(@owner).add_member(@plan_id, @colleague.id, role: "viewer")
      handler(@owner).archive_plan(@plan_id)
    end

    should "be archived and restored by an editor, and by nobody else" do
      event = event_store.read.stream(EventStreamNaming.plan_stream(@plan_id)).to_a.last
      assert_kind_of TeamPlanning::Events::PlanArchived, event
      assert_equal({ plan_id: @plan_id, archived_by_id: @editor.id }, event.data)

      assert_equal "No such plan", assert_raises(TeamPlanning::Error) { handler(@colleague_context).restore_plan(@plan_id) }.message
      assert_not handler(@owner).restore_plan(@plan_id).archived?
      assert_equal "No such plan", assert_raises(TeamPlanning::Error) { handler(@colleague_context).archive_plan(@plan_id) }.message
    end

    should "refuse an editor's write with the archived message" do
      error = assert_raises(TeamPlanning::Error) { handler(@owner).rename_plan(@plan_id, "Later") }
      assert_equal TeamPlanning::PlanAggregate::ARCHIVED, error.message
    end

    should "let a viewer leave" do
      assert_not handler(@colleague_context).remove_member(@plan_id, @colleague.id).member?(@colleague.id)
    end

    should "keep its last reachable editor and pay holder" do
      error = assert_raises(TeamPlanning::Error) { handler(@owner).remove_member(@plan_id, @editor.id) }
      assert_equal TeamPlanning::PlanAggregate::EDITOR_NEEDED[:archived], error.message
    end

    should "keep a viewer who is its last pay holder until an editor restores it" do
      handler(@owner).restore_plan(@plan_id)
      handler(@owner).grant_see_pay(@plan_id, @colleague.id)
      handler(@owner).withdraw_see_pay(@plan_id, @editor.id)
      handler(@owner).archive_plan(@plan_id)

      error = assert_raises(TeamPlanning::Error) { handler(@colleague_context).remove_member(@plan_id, @colleague.id) }
      assert_equal TeamPlanning::PlanAggregate::PAY_HOLDER_NEEDED[:archived], error.message
      assert_not handler(@owner).restore_plan(@plan_id).archived?
    end

    should "freeze once its editor leaves the organisation, and let a tenant admin delete it" do
      @editor.update!(status: "inactive")

      assert PlanPolicy.frozen?(ActsAsTenant.with_tenant(@tenant) { TeamPlanningPlan.find(@plan_id) })
      assert handler(@admin).delete_frozen_plan(@plan_id, reason: "Its only editor left").deleted?
    end

    should "let a tenant admin restore pay to its reachable editors while it stays archived" do
      second = create(:person, tenant: @tenant)
      context_for(second)
      handler(@owner).restore_plan(@plan_id)
      handler(@owner).add_member(@plan_id, second.id, role: "editor")
      handler(@owner).archive_plan(@plan_id)
      @editor.update!(status: "inactive")

      plan = handler(@admin).restore_see_pay(@plan_id)
      assert plan.sees_pay?(second.id)
      assert plan.archived?
    end
  end

  context "a plan's creator and everyone else" do
    setup { handler(@admin).create_plan(@plan_id, name: "Next year", base_on: "2026-11-14") }

    should "let the creator rename and delete it" do
      handler(@admin).rename_plan(@plan_id, "Two-year plan")
      handler(@admin).delete_plan(@plan_id)

      types = event_store.read.stream(EventStreamNaming.plan_stream(@plan_id)).map(&:class)
      assert_equal [ TeamPlanning::Events::PlanCreated, TeamPlanning::Events::PlanRenamed, TeamPlanning::Events::PlanDeleted ], types
    end

    should "read as missing to another tenant admin, as an unknown id does" do
      other_admin = context_for(create(:person, tenant: @tenant), role: :admin)
      [ -> { handler(other_admin).rename_plan(@plan_id, "Theirs") }, -> { handler(other_admin).delete_plan(@plan_id) },
        -> { handler(@admin).rename_plan(SecureRandom.uuid_v7, "Ghost") } ].each do |command|
        assert_equal "No such plan", assert_raises(TeamPlanning::Error, &command).message
      end
    end

    should "read a plan from another tenant as missing" do
      other = create(:tenant)
      ActsAsTenant.with_tenant(other) do
        stranger = context_for(create(:person, tenant: other), role: :admin, tenant: other)
        error = assert_raises(TeamPlanning::Error) { handler(stranger).rename_plan(@plan_id, "Theirs") }
        assert_equal "No such plan", error.message
      end
    end
  end

  private

  def handler(actor) = TeamPlanning::CommandHandler.new(actor:)

  def event_store = Rails.configuration.event_store

  def key_store = PlanKeyStore.new

  def context_for(person, role: :member, tenant: @tenant, **grants)
    user = create(:user)
    tenant_user = create(:tenant_user, tenant:, user:, person:, role:, **grants)
    AuthorizationContext.new(user:, tenant_user:, person:)
  end
end
