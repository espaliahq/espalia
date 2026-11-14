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

    should "refuse a member who is not a tenant admin" do
      member = context_for(create(:person, tenant: @tenant))
      error = assert_raises(Pundit::NotAuthorizedError) { handler(member).create_plan(@plan_id, name: "Mine", base_on: "2026-11-14") }
      assert_equal "Only a tenant admin can create a plan", error.message
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

  context "a plan's creator and everyone else" do
    setup { handler(@admin).create_plan(@plan_id, name: "Next year", base_on: "2026-11-14") }

    should "let the creator rename and delete it" do
      handler(@admin).rename_plan(@plan_id, "Two-year plan")
      handler(@admin).delete_plan(@plan_id)

      types = event_store.read.stream(EventStreamNaming.plan_stream(@plan_id)).map(&:class)
      assert_equal [ TeamPlanning::Events::PlanCreated, TeamPlanning::Events::PlanRenamed, TeamPlanning::Events::PlanDeleted ], types
    end

    should "refuse another tenant admin" do
      other_admin = context_for(create(:person, tenant: @tenant), role: :admin)
      assert_raises(Pundit::NotAuthorizedError) { handler(other_admin).rename_plan(@plan_id, "Theirs") }
      assert_raises(Pundit::NotAuthorizedError) { handler(other_admin).delete_plan(@plan_id) }
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

  def context_for(person, role: :member, tenant: @tenant)
    user = create(:user)
    tenant_user = create(:tenant_user, tenant:, user:, person:, role:)
    AuthorizationContext.new(user:, tenant_user:, person:)
  end
end
