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
end
