# frozen_string_literal: true

require "test_helper"

# Role and link events on TenantAccountGrants, written straight to the
# stream ([#539](https://github.com/espaliahq/espalia/issues/539) Track B).
# They stay out of the old stream, which the release before the move loads.
class AccountGrants::LaterEventsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    as_tenant do
      @ada, @bo = Array.new(2) { create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant)) }
      AccountGrants::CommandHandler.new.add(:team_planner, @bo)
    end
    @later = [
      AccountGrants::Events::AccountRoleSet.new(data: {
        tenant_user_id: @ada.id, person_id: @ada.person_id, role: "admin", effective_on: "2026-11-24",
        set_by_id: nil, already_held: true
      }),
      AccountGrants::Events::AccountRoleSet.new(data: {
        tenant_user_id: @bo.id, person_id: @bo.person_id, role: "member", effective_on: "2026-11-24",
        set_by_id: nil, already_held: true
      }),
      AccountGrants::Events::AccountRoleRemoved.new(data: {
        tenant_user_id: @bo.id, person_id: @bo.person_id, effective_on: "2026-11-24", removed_by_id: nil
      }),
      AccountGrants::Events::AccountLinkedToPerson.new(data: {
        tenant_user_id: @ada.id, person_id: @ada.person_id, effective_on: "2026-11-24", linked_by_id: nil, match: nil, already_held: true
      }),
      AccountGrants::Events::AccountLinkedToPerson.new(data: {
        tenant_user_id: @bo.id, person_id: @bo.person_id, effective_on: "2026-11-24", linked_by_id: nil, match: nil, already_held: true
      }),
      AccountGrants::Events::AccountUnlinkedFromPerson.new(data: {
        tenant_user_id: @bo.id, person_id: @bo.person_id, effective_on: "2026-11-24", unlinked_by_id: nil, reason: "admin"
      })
    ]
    event_store.with_metadata(tenant_id: @tenant.id) do
      event_store.append(@later, stream_name: EventStreamNaming.tenant_account_grants_stream(tenant: @tenant))
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def event_store = Rails.configuration.event_store

  def types(stream) = event_store.read.stream(stream).map(&:event_type)

  should "load them, and still give and take back grants" do
    grants = as_tenant { AccountGrants::CommandHandler.new.add(:org_graph_editor, @ada) }

    assert_equal({ @ada.id => "admin" }, grants.roles)
    assert_equal({ @ada.id => @ada.person_id }, grants.role_holders)
    assert_equal "admin", grants.role_of(@ada.id)
    assert_nil grants.role_of(@bo.id)
    assert_equal({ @ada.id => @ada.person_id }, grants.links)
    assert grants.holds?(:org_graph_editor, @ada.id)
    assert TenantUser.find(@ada.id).org_graph_editor
  end

  should "link nothing back into the old stream" do
    as_tenant { AccountGrants::CommandHandler.new.add(:org_graph_editor, @ada) }

    assert_empty types(EventStreamNaming.account_grants_stream(tenant: @tenant))
    assert_equal 8, types(EventStreamNaming.tenant_account_grants_stream(tenant: @tenant)).size
  end

  should "include roles and links in the read without the lock" do
    grants = as_tenant { AccountGrants::Repository.new.load_grants }

    assert_equal({ @ada.id => "admin" }, grants.roles)
    assert_equal({ @ada.id => @ada.person_id }, grants.links)
    assert grants.holds?(:team_planner, @bo.id)
  end

  should "rebuild the flags and reconcile the grants past them" do
    AccountGrants::Projections::AccountFlags.reset!(tenant: @tenant)
    report = AccountGrants::Reconciliation.new(@tenant).call

    assert_equal [ 0, 0 ], [ report.added, report.removed ]
    assert TenantUser.find(@bo.id).team_planner
  end
end
