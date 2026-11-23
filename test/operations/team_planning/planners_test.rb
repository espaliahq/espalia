# frozen_string_literal: true

require "test_helper"

class Operations::TeamPlanning::PlannersTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = account(:admin, name: "Ada Admin")
      @member = account(:member, name: "Mo Member")
      @planner = account(:member, name: "Pat Planner", team_planner: true)
    end
  end

  def account(role, name:, team_planner: false)
    create(:tenant_user, tenant: @tenant, role:, team_planner:, person: create(:person, tenant: @tenant, name:))
  end

  def context(account = @admin) = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) { "Operations::TeamPlanning::#{operation}".constantize.call(context: context(as), params:) }
  end

  def names(list) = list.pluck(:name)

  def grant_events
    Rails.configuration.event_store.read.stream(EventStreamNaming.account_grants_stream(tenant: @tenant)).to_a
  end

  def call_over_mcp(operation, **params)
    AuditMetadata.with(acting_via: :mcp, actor_id: @admin.person_id) { call(operation, **params) }
  end

  should "list the planners an admin chose apart from the admins" do
    result = call(:Planners)

    assert_equal [ "Pat Planner" ], names(result[:planners])
    assert_equal [ "Ada Admin" ], names(result[:admins])
    assert_equal @planner.person_id, result[:planners].first[:person_id]
  end

  should "make a member a planner, and take it back" do
    assert_equal [ "Mo Member", "Pat Planner" ], names(call(:AddPlanner, person_id: @member.person_id)[:planners])
    assert @member.reload.team_planner?

    assert_equal [ "Pat Planner" ], names(call(:RemovePlanner, person_id: @member.person_id)[:planners])
    assert_not @member.reload.team_planner?
  end

  should "refuse to add or remove an admin, who may always create plans" do
    assert_raises(Operations::Base::ParameterError) { call(:AddPlanner, person_id: @admin.person_id) }
    assert_raises(Operations::Base::ParameterError) { call(:RemovePlanner, person_id: @admin.person_id) }
  end

  should "refuse someone who has left" do
    ActsAsTenant.with_tenant(@tenant) { @member.person.update!(status: "inactive") }

    assert_raises(Operations::Base::ParameterError) { call(:AddPlanner, person_id: @member.person_id) }
    assert_not @member.reload.team_planner?
  end

  should "refuse a person with no account in this organisation" do
    stranger = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant) }

    assert_raises(Operations::Base::ParameterError) { call(:AddPlanner, person_id: stranger.id) }
  end

  should "not reach an account in another organisation" do
    other = create(:tenant)
    outsider = ActsAsTenant.with_tenant(other) do
      create(:tenant_user, tenant: other, role: :member, person: create(:person, tenant: other))
    end

    assert_raises(Operations::Base::ParameterError) { call(:AddPlanner, person_id: outsider.person_id) }
    assert_not outsider.reload.team_planner?
  end

  should "leave the choice to admins, even a planner may not choose" do
    [ @planner, @member ].each do |account|
      assert_raises(Pundit::NotAuthorizedError) { call(:Planners, as: account) }
      assert_raises(Pundit::NotAuthorizedError) { call(:AddPlanner, as: account, person_id: @member.person_id) }
    end
    assert_not @member.reload.team_planner?
  end

  should "record each grant and removal as one event, saying who made it and how" do
    call_over_mcp(:AddPlanner, person_id: @member.person_id)
    call_over_mcp(:RemovePlanner, person_id: @member.person_id)

    added, removed = grant_events
    assert_equal [ AccountGrants::Events::PlannerAdded, AccountGrants::Events::PlannerRemoved ], grant_events.map(&:class)
    assert_equal({ tenant_user_id: @member.id, person_id: @member.person_id, effective_on: @tenant.today.iso8601,
                   added_by_id: @admin.person_id, already_held: false }, added.data)
    assert_equal @admin.person_id, removed.data[:removed_by_id]
    [ added, removed ].each do |event|
      assert_equal "mcp", event.metadata[:acting_via]
      assert_equal @admin.person_id, event.metadata[:actor_id]
      assert_equal @tenant.id, event.metadata[:tenant_id]
    end
  end

  should "write no event for a refusal" do
    assert_raises(Pundit::NotAuthorizedError) { call(:AddPlanner, as: @member, person_id: @member.person_id) }
    assert_raises(Operations::Base::ParameterError) { call(:AddPlanner, person_id: @admin.person_id) }
    assert_raises(Operations::Base::ParameterError) { call(:RemovePlanner, person_id: @admin.person_id) }

    assert_empty grant_events
  end
end
