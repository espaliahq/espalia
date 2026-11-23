# frozen_string_literal: true

require "test_helper"

class AccountGrants::AggregateTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:person, tenant: @tenant)
      @account = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
    end
  end

  def handler = AccountGrants::CommandHandler.new

  def grants = AccountGrants::Repository.new.load_grants

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def stream_events
    Rails.configuration.event_store.read.stream(EventStreamNaming.account_grants_stream(tenant: @tenant)).to_a
  end

  def remove(grant, account = @account, **options)
    handler.remove(grant, tenant_user_id: account.id, person_id: account.person_id, **options)
  end

  should "grant, remove and grant again" do
    as_tenant do
      handler.add(:org_graph_editor, @account, added_by_id: @admin.id)
      remove(:org_graph_editor, removed_by_id: @admin.id)
      handler.add(:org_graph_editor, @account, added_by_id: @admin.id)

      assert grants.holds?(:org_graph_editor, @account.id)
    end

    events = stream_events
    assert_equal %w[OrgGraphEditorAdded OrgGraphEditorRemoved OrgGraphEditorAdded], events.map { it.class.name.demodulize }
    assert_equal({ tenant_user_id: @account.id, person_id: @account.person_id, effective_on: @tenant.today.iso8601,
                   added_by_id: @admin.id, already_held: false }, events.first.data)
    assert_equal @admin.id, events.second.data[:removed_by_id]
    assert(events.all? { it.metadata[:tenant_id] == @tenant.id })
  end

  should "write nothing for a grant already held, or a removal of one not held" do
    as_tenant do
      remove(:team_planner)
      handler.add(:team_planner, @account)
      handler.add(:team_planner, @account)
      remove(:org_graph_editor)
    end

    assert_equal %w[PlannerAdded], stream_events.map { it.class.name.demodulize }
  end

  should "keep the two grants apart" do
    as_tenant do
      handler.add(:team_planner, @account)

      assert grants.holds?(:team_planner, @account.id)
      assert_not grants.holds?(:org_graph_editor, @account.id)
    end
  end

  should "start a recreated account without the grant its person's old account held" do
    as_tenant do
      handler.add(:org_graph_editor, @account)
      person = @account.person
      @account.destroy!
      recreated = create(:tenant_user, tenant: @tenant, person:)

      assert_not grants.holds?(:org_graph_editor, recreated.id)

      handler.add(:org_graph_editor, recreated)
      assert grants.holds?(:org_graph_editor, recreated.id)
      assert_equal 2, stream_events.size
    end
  end

  should "refuse an unknown grant" do
    as_tenant { assert_raises(KeyError) { handler.add(:owner, @account) } }
  end
end
