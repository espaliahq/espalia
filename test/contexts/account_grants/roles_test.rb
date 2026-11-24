# frozen_string_literal: true

require "test_helper"

# An account's role as events on the grants stream (#540).
class AccountGrants::RolesTest < ActiveSupport::TestCase
  ROLE_EVENTS = [ AccountGrants::Events::AccountRoleSet, AccountGrants::Events::AccountRoleRemoved ].freeze

  setup do
    @tenant = create(:tenant)
    as_tenant do
      @actor = create(:person, tenant: @tenant)
      @ada = account(:admin)
      @bo = account(:admin)
      @cy = account(:member)
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def account(role) = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant), role:)

  def handler = AccountGrants::CommandHandler.new

  def roles = as_tenant { AccountGrants::Repository.new.reading_locked(&:roles) }

  def role_events(stream = EventStreamNaming.tenant_account_grants_stream(tenant: @tenant))
    Rails.configuration.event_store.read.stream(stream).of_type(ROLE_EVENTS).to_a
  end

  def column(account) = TenantUser.unscoped.find(account.id).role

  def reconcile = AccountGrants::RoleReconciliation.new(@tenant).call

  context "set_role" do
    should "record the roles the table holds before the change, then the change with its actor" do
      as_tenant { handler.set_role(@cy, :admin, set_by_id: @actor.id) }

      assert_equal({ @ada.id => "admin", @bo.id => "admin", @cy.id => "admin" }, roles)
      last = role_events.last
      assert_equal({ tenant_user_id: @cy.id, person_id: @cy.person_id, role: "admin", effective_on: @tenant.today.iso8601,
                     set_by_id: @actor.id, already_held: false }, last.data)
      assert_equal [ true, true, true, false ], role_events.map { it.data[:already_held] }
      assert_equal "admin", column(@cy)
    end

    should "write nothing for the role an account already has" do
      as_tenant { handler.set_role(@cy, :member) }

      assert_equal 3, role_events.size
      assert(role_events.all? { it.data[:already_held] })
    end

    should "demote an admin while another remains, and refuse to demote the last" do
      as_tenant { handler.set_role(@ada, :member) }
      assert_equal "member", column(@ada)

      assert_raises(AccountGrants::Aggregate::LastAdmin) { as_tenant { handler.set_role(@bo, :member) } }
      assert_equal "admin", column(@bo)
    end

    should "not count an admin whose account was destroyed or forgotten" do
      as_tenant { handler.set_role(@cy, :member) }
      as_tenant { @ada.destroy! }

      assert_raises(AccountGrants::Aggregate::LastAdmin) { as_tenant { handler.set_role(@bo, :member) } }

      as_tenant { handler.set_role(@cy, :admin) }
      TenantUser.where(id: @cy.id).update_all(person_id: nil, user_id: nil, forgotten_at: Time.current)
      assert_raises(AccountGrants::Aggregate::LastAdmin) { as_tenant { handler.set_role(@bo, :member) } }
      assert_equal "admin", column(@cy), "a forgotten account's row is left as it is"
    end

    should "act on a role the previous release wrote straight to the column" do
      as_tenant { handler.set_role(@cy, :member) }
      @bo.update_columns(role: "member")

      assert_raises(AccountGrants::Aggregate::LastAdmin) { as_tenant { handler.set_role(@ada, :member) } }
      assert_equal "admin", column(@ada)
    end

    should "refuse a role it doesn't know" do
      assert_raises(ArgumentError) { as_tenant { handler.set_role(@cy, :owner) } }
    end
  end

  should "record a new account's role without reading the others" do
    as_tenant do
      dee = account(:member)
      handler.record_new_account(dee, set_by_id: @actor.id)

      assert_equal({ dee.id => "member" }, roles)
      assert_equal @actor.id, role_events.sole.data[:set_by_id]
    end
  end

  context "RoleReconciliation" do
    should "record each live role as already held, and nothing when run again" do
      assert_equal 3, reconcile.added
      assert(role_events.all? { it.data[:already_held] && it.data[:set_by_id].nil? })

      assert_equal 0, reconcile.added + reconcile.removed
    end

    should "record a role changed outside the events, and a destroyed account's as removed" do
      reconcile
      @cy.update_columns(role: "admin")
      id, person_id = @bo.id, @bo.person_id
      as_tenant { @bo.destroy! }

      reconcile
      assert_equal({ @ada.id => "admin", @cy.id => "admin" }, roles)
      assert_equal({ tenant_user_id: id, person_id:, effective_on: @tenant.today.iso8601 }, role_events.last.data)
    end
  end

  context "the projection" do
    should "keep a role the stream doesn't record through a reset, and set the ones it does" do
      as_tenant { handler.record_new_account(@cy) }
      @cy.update_columns(role: "admin")
      @ada.update_columns(role: "member")

      AccountGrants::Projections::AccountFlags.reset!(tenant: @tenant)

      assert_equal [ "member", "admin", "member" ], [ @ada, @bo, @cy ].map { column(it) }
    end
  end

  should "keep role events out of the old stream the previous release loads" do
    as_tenant { handler.set_role(@cy, :admin) }
    as_tenant { handler.add(:team_planner, @cy) }

    assert_empty role_events(EventStreamNaming.account_grants_stream(tenant: @tenant))
    legacy = Rails.configuration.event_store.read.stream(EventStreamNaming.account_grants_stream(tenant: @tenant)).to_a
    assert_equal [ AccountGrants::Events::PlannerAdded ], legacy.map(&:class)
  end
end
