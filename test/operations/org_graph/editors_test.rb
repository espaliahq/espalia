# frozen_string_literal: true

require "test_helper"

class Operations::OrgGraph::EditorsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = account(:admin, name: "Ada Admin")
      @member = account(:member, name: "Mo Member")
      @editor = account(:member, name: "Eve Editor", org_graph_editor: true)
    end
  end

  def account(role, name:, org_graph_editor: false)
    create(:tenant_user, tenant: @tenant, role:, org_graph_editor:, person: create(:person, tenant: @tenant, name:))
  end

  def context(account = @admin) = AuthorizationContext.new(user: account.user, tenant_user: account, person: account.person)

  def call(operation, as: @admin, **params)
    ActsAsTenant.with_tenant(@tenant) { "Operations::OrgGraph::#{operation}".constantize.call(context: context(as), params:) }
  end

  def names(list) = list.pluck(:name)

  def grant_events
    Rails.configuration.event_store.read.stream(EventStreamNaming.tenant_account_grants_stream(tenant: @tenant)).to_a
  end

  def call_over_mcp(operation, **params)
    AuditMetadata.with(acting_via: :mcp, actor_id: @admin.person_id) { call(operation, **params) }
  end

  should "list the editors an admin chose apart from the admins" do
    result = call(:Editors)

    assert_equal [ "Eve Editor" ], names(result[:editors])
    assert_equal [ "Ada Admin" ], names(result[:admins])
    assert_equal @editor.person_id, result[:editors].first[:person_id]
  end

  should "make a member an editor, and take it back" do
    assert_equal [ "Eve Editor", "Mo Member" ], names(call(:AddEditor, person_id: @member.person_id)[:editors])
    assert @member.reload.org_graph_editor?

    assert_equal [ "Eve Editor" ], names(call(:RemoveEditor, person_id: @member.person_id)[:editors])
    assert_not @member.reload.org_graph_editor?
  end

  should "refuse to add or remove an admin, who may always edit" do
    assert_raises(Operations::Base::ParameterError) { call(:AddEditor, person_id: @admin.person_id) }
    assert_raises(Operations::Base::ParameterError) { call(:RemoveEditor, person_id: @admin.person_id) }
  end

  should "refuse someone who has left" do
    ActsAsTenant.with_tenant(@tenant) { @member.person.update!(status: "inactive") }

    assert_raises(Operations::Base::ParameterError) { call(:AddEditor, person_id: @member.person_id) }
    assert_not @member.reload.org_graph_editor?
  end

  should "refuse a person with no account in this organisation" do
    stranger = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant) }

    assert_raises(Operations::Base::ParameterError) { call(:AddEditor, person_id: stranger.id) }
  end

  should "not reach an account in another organisation" do
    other = create(:tenant)
    outsider = ActsAsTenant.with_tenant(other) do
      create(:tenant_user, tenant: other, role: :member, person: create(:person, tenant: other))
    end

    assert_raises(Operations::Base::ParameterError) { call(:AddEditor, person_id: outsider.person_id) }
    assert_not outsider.reload.org_graph_editor?
  end

  should "leave the choice to admins, even an editor may not choose" do
    [ @editor, @member ].each do |account|
      assert_raises(Pundit::NotAuthorizedError) { call(:Editors, as: account) }
      assert_raises(Pundit::NotAuthorizedError) { call(:AddEditor, as: account, person_id: @member.person_id) }
    end
    assert_not @member.reload.org_graph_editor?
  end

  should "record each grant and removal as one event, saying who made it and how" do
    call_over_mcp(:AddEditor, person_id: @member.person_id)
    call_over_mcp(:RemoveEditor, person_id: @member.person_id)

    added, removed = grant_events
    assert_equal [ AccountGrants::Events::OrgGraphEditorAdded, AccountGrants::Events::OrgGraphEditorRemoved ], grant_events.map(&:class)
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
    assert_raises(Pundit::NotAuthorizedError) { call(:AddEditor, as: @member, person_id: @member.person_id) }
    assert_raises(Operations::Base::ParameterError) { call(:AddEditor, person_id: @admin.person_id) }
    assert_raises(Operations::Base::ParameterError) { call(:RemoveEditor, person_id: @admin.person_id) }

    assert_empty grant_events
  end

  def listed(name, result = call(:Editors)) = result[:editors].find { it[:name] == name }

  should "say since when each editor holds it, and who made them one" do
    travel_to Date.new(2026, 11, 2)
    result = call(:AddEditor, person_id: @member.person_id)

    assert_equal({ person_id: @member.person_id, name: "Mo Member", since: "2026-11-02", added_by: "Ada Admin", already_held: false },
                 listed("Mo Member", result))
    assert_equal listed("Mo Member", result), listed("Mo Member")
  end

  should "leave since and who blank for a flag the stream doesn't hold yet, and fill since once it is reconciled" do
    assert_equal [ nil, nil, nil ], listed("Eve Editor").values_at(:since, :added_by, :already_held)

    AccountGrants::Reconciliation.new(@tenant).call

    assert_equal [ @tenant.today.iso8601, nil, true ], listed("Eve Editor").values_at(:since, :added_by, :already_held)
  end

  should "name a editor given by someone no longer on record as a former member" do
    ActsAsTenant.with_tenant(@tenant) { AccountGrants::CommandHandler.new.add(:org_graph_editor, @member, added_by_id: SecureRandom.uuid_v7) }

    assert_equal Person::FORMER_MEMBER, listed("Mo Member")[:added_by]
  end

  should "leave out a editor whose account is gone" do
    call(:AddEditor, person_id: @member.person_id)
    ActsAsTenant.with_tenant(@tenant) { @member.destroy! }

    assert_equal [ "Eve Editor" ], names(call(:Editors)[:editors])
  end
end
