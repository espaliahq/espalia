# frozen_string_literal: true

require "test_helper"

class AccountGrants::CommandHandlerTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    as_tenant do
      @admin = create(:person, tenant: @tenant)
      @account = create(:tenant_user, tenant: @tenant, person: create(:person, tenant: @tenant))
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def handler = AccountGrants::CommandHandler.new

  def grants = AccountGrants::Repository.new.load_grants

  def stream_events
    Rails.configuration.event_store.read.stream(EventStreamNaming.tenant_account_grants_stream(tenant: @tenant)).to_a
  end

  def remove
    handler.remove(:org_graph_editor, tenant_user_id: @account.id, person_id: @account.person_id, removed_by_id: @admin.id)
  end

  context "when a release before the stream changed only the flag" do
    should "record a grant it gave before removing it, so the removal takes" do
      @account.update_columns(org_graph_editor: true)

      as_tenant { remove }

      assert_equal [ [ "OrgGraphEditorAdded", true, nil ], [ "OrgGraphEditorRemoved", nil, @admin.id ] ],
                   stream_events.map { [ it.class.name.demodulize, it.data[:already_held], it.data[:removed_by_id] ] }
      assert_not @account.reload.org_graph_editor
    end

    should "record a grant it took away before giving it again, so the grant takes" do
      as_tenant { handler.add(:org_graph_editor, @account, added_by_id: @admin.id) }
      @account.update_columns(org_graph_editor: false)

      as_tenant { handler.add(:org_graph_editor, @account, added_by_id: @admin.id) }

      assert_equal [ [ "OrgGraphEditorAdded", @admin.id ], [ "OrgGraphEditorRemoved", nil ], [ "OrgGraphEditorAdded", @admin.id ] ],
                   stream_events.map { [ it.class.name.demodulize, it.data[:added_by_id] || it.data[:removed_by_id] ] }
      assert @account.reload.org_graph_editor
      assert(as_tenant { grants.holds?(:org_graph_editor, @account.id) })
    end
  end

  should "record nothing extra when the flag and the stream agree" do
    as_tenant do
      handler.add(:org_graph_editor, @account, added_by_id: @admin.id)
      remove
    end

    assert_equal %w[OrgGraphEditorAdded OrgGraphEditorRemoved], stream_events.map { it.class.name.demodulize }
  end
end
