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
    Rails.configuration.event_store.read.stream(EventStreamNaming.tenant_account_grants_stream(tenant: @tenant)).to_a
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

  def listed(name, result = call(:Planners)) = result[:planners].find { it[:name] == name }

  should "say since when each planner holds it, and who made them one" do
    travel_to Date.new(2026, 11, 2)
    result = call(:AddPlanner, person_id: @member.person_id)

    assert_equal({ person_id: @member.person_id, name: "Mo Member", since: "2026-11-02", added_by: "Ada Admin", already_held: false },
                 listed("Mo Member", result))
    assert_equal listed("Mo Member", result), listed("Mo Member")
  end

  should "leave since and who blank for a flag the stream doesn't hold yet, and fill since once it is reconciled" do
    assert_equal [ nil, nil, nil ], listed("Pat Planner").values_at(:since, :added_by, :already_held)

    AccountGrants::Reconciliation.new(@tenant).call

    assert_equal [ @tenant.today.iso8601, nil, true ], listed("Pat Planner").values_at(:since, :added_by, :already_held)
  end

  should "name a planner given by someone no longer on record as a former member" do
    ActsAsTenant.with_tenant(@tenant) { AccountGrants::CommandHandler.new.add(:team_planner, @member, added_by_id: SecureRandom.uuid_v7) }

    assert_equal Person::FORMER_MEMBER, listed("Mo Member")[:added_by]
  end

  should "leave out a planner whose account is gone" do
    call(:AddPlanner, person_id: @member.person_id)
    ActsAsTenant.with_tenant(@tenant) { @member.destroy! }

    assert_equal [ "Pat Planner" ], names(call(:Planners)[:planners])
  end

  context "a person with two accounts, as a link made before links were events can leave" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @twin = create(:tenant_user, tenant: @tenant, role: :member, team_planner: true, person: @planner.person)
        @lone = create(:tenant_user, tenant: @tenant, role: :member, person: @member.person)
      end
    end

    should "refuse the grant and write no event" do
      error = assert_raises(Operations::Base::ParameterError) { call(:AddPlanner, person_id: @member.person_id) }

      assert_match "more than one account", error.message
      assert_not @member.reload.team_planner?
      assert_not @lone.reload.team_planner?
      assert_empty grant_events
    end

    should "take the right from both accounts" do
      call(:RemovePlanner, person_id: @planner.person_id)

      assert_not @planner.reload.team_planner?
      assert_not @twin.reload.team_planner?
    end

    should "write nothing when neither account holds the right, as for a person with one" do
      single = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, role: :member, person: create(:person, tenant: @tenant)) }

      assert_equal call(:RemovePlanner, person_id: single.person_id), call(:RemovePlanner, person_id: @member.person_id)
      assert_empty grant_events
    end

    should "take the right from an admin account too, so a demotion can't bring it back" do
      ActsAsTenant.with_tenant(@tenant) { @planner.update!(role: :admin) }

      call(:RemovePlanner, person_id: @planner.person_id)

      assert_not @planner.reload.team_planner?
      assert_not @twin.reload.team_planner?
    end

    should "take the right from accounts that are all admins when one still carries it" do
      ActsAsTenant.with_tenant(@tenant) { [ @planner, @twin ].each { it.update!(role: :admin) } }

      call(:RemovePlanner, person_id: @planner.person_id)

      assert_not @planner.reload.team_planner?
      assert_not @twin.reload.team_planner?
    end

    should "refuse when every account is an admin" do
      ActsAsTenant.with_tenant(@tenant) { [ @member, @lone ].each { it.update!(role: :admin) } }

      assert_raises(Operations::Base::ParameterError) { call(:RemovePlanner, person_id: @member.person_id) }
      assert_empty grant_events
    end

    should "clear neither account when removing from the second fails" do
      build = AccountGrants::Aggregate.method(:new)
      failing = lambda do
        build.call.tap do |grants|
          removals = 0
          grants.define_singleton_method(:remove) do |*args, **kwargs|
            raise "second removal failed" if (removals += 1) == 2

            super(*args, **kwargs)
          end
        end
      end

      AccountGrants::Aggregate.stub(:new, failing) do
        assert_raises(RuntimeError) { call(:RemovePlanner, person_id: @planner.person_id) }
      end

      assert @planner.reload.team_planner?
      assert @twin.reload.team_planner?
      assert_empty grant_events
    end
  end
end
