# frozen_string_literal: true

require "test_helper"

# Links the previous release wrote straight to `tenant_users.person_id`,
# recorded on the grants stream (#539 2b).
class AccountGrants::LinkReconciliationTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    as_tenant do
      @ada, @bo = Array.new(2) { create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant)) }
      @unlinked = create(:tenant_user, tenant: @tenant, person: nil)
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def reconcile = AccountGrants::LinkReconciliation.new(@tenant).call

  def links = as_tenant { AccountGrants::Repository.new.reading_locked(&:links) }

  def unlinks
    Rails.configuration.event_store.read.stream(EventStreamNaming.tenant_account_grants_stream(tenant: @tenant))
      .of_type([ AccountGrants::Events::AccountUnlinkedFromPerson ]).map { [ it.data[:tenant_user_id], it.data[:reason] ] }
  end

  def report(added, removed, changed) = TenantStreams::Reconciliation::Report.new(added:, removed:, changed:)

  should "record each live link as already held, and nothing when run again" do
    assert_equal report(2, 0, 0), reconcile
    assert_equal({ @ada.id => @ada.person_id, @bo.id => @bo.person_id }, links)

    assert_equal report(0, 0, 0), reconcile
  end

  should "record an erase by the previous release as forgotten, and nothing when run again" do
    reconcile
    now = Time.current
    Person.unscoped.where(id: @ada.person_id)
      .update_all(name: Person::FORMER_MEMBER, email: nil, external_id: nil, forgotten_at: now)
    TenantUser.where(person_id: @ada.person_id)
      .update_all(person_id: nil, user_id: nil, slack_user_id: nil, forgotten_at: now, updated_at: now)

    assert_equal report(0, 1, 0), reconcile
    assert_equal [ [ @ada.id, "forgotten" ] ], unlinks
    assert_equal({ @bo.id => @bo.person_id }, links)

    assert_equal report(0, 0, 0), reconcile
  end

  should "record a destroyed account as removed, a cleared link as cleared, and a moved link as a change" do
    reconcile
    carl = as_tenant { create(:person, tenant: @tenant) }
    as_tenant { @ada.destroy! }
    @bo.update_columns(person_id: carl.id)
    @unlinked.update_columns(person_id: @ada.person_id)

    assert_equal report(1, 1, 1), reconcile
    assert_equal [ [ @ada.id, "account_removed" ], [ @bo.id, "cleared" ] ], unlinks.sort
    assert_equal({ @bo.id => carl.id, @unlinked.id => @ada.person_id }, links)

    @unlinked.update_columns(person_id: nil)
    reconcile
    assert_includes unlinks, [ @unlinked.id, "cleared" ]
  end

  should "record a person two accounts share, and log it" do
    @unlinked.update_columns(person_id: @ada.person_id)
    logged = []

    Rails.logger.stub(:warn, ->(message) { logged << message }) { reconcile }

    assert_equal [ @ada.id, @unlinked.id ].sort, links.select { |_, person| person == @ada.person_id }.keys.sort
    assert_equal [ "[account_links] tenant=#{@tenant.id} person=#{@ada.person_id} is linked to 2 accounts" ], logged
  end
end
