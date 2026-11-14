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
      assert_equal "Only someone active in this organisation can join a plan", error.message
      assert_raises(TeamPlanning::Error) { handler(@admin).add_member(@plan_id, SecureRandom.uuid_v7, role: "viewer") }
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

  def context_for(person, role: :member, tenant: @tenant, **grants)
    user = create(:user)
    tenant_user = create(:tenant_user, tenant:, user:, person:, role:, **grants)
    AuthorizationContext.new(user:, tenant_user:, person:)
  end
end
