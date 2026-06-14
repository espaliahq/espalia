# frozen_string_literal: true

require "test_helper"

# Confirms the MCP recent-activity read returns metadata-only feed entries
# (most-recent first) for a framework, and is gated by FrameworkPolicy's
# suggestion-view authority — the same gate the explorer's context pane uses.
class Operations::Frameworks::RecentActivityTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @user = create(:user)
    @outsider = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email)
      @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: @person, role: :member)
      @outsider_person = create(:person, tenant: @tenant, email: @outsider.email)
      @outsider_tu = create(:tenant_user, tenant: @tenant, user: @outsider, person: @outsider_person, role: :member)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7

      Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id, actor_id: @person.id) do
        handler.create_framework(@framework_id, "Engineering")
        handler.add_role_family(@framework_id, rfid, "Eng")
        handler.add_role(@framework_id, rid, rfid, "SWE", "E", "ic")
        handler.add_level(@framework_id, SecureRandom.uuid_v7, rid, 1, "E1", "E1")
        handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
        handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, cat_id, "Critical Thinking")
        handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @cap_id, rid)
        handler.publish_version(@framework_id, "v1")
        handler.add_collaborator(@framework_id, @person.id.to_s, "owner", added_by: @person.id.to_s)
      end
    end

    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
  end

  def call_op(params = { framework_id: @framework_id })
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Frameworks::RecentActivity.call(context: @context, params: params)
    end
  end

  context "as an owner collaborator" do
    should "return metadata-only entries, most-recent first" do
      result = call_op

      assert_equal @framework_id, result[:framework_id]
      kinds = result[:activity].map { |e| e[:kind] }
      assert_includes kinds, "capability_added"
      assert_includes kinds, "version_published"
      # capability_added is anchored to its capability with id + name.
      cap_entry = result[:activity].find { |e| e[:kind] == "capability_added" }
      assert_equal @cap_id, cap_entry.dig(:capability, :id)
      assert_equal "Critical Thinking", cap_entry.dig(:capability, :name)
      # Most-recent first: version_published comes before the draft open.
      assert_operator kinds.index("version_published"), :<, kinds.index("draft_opened")
    end

    should "cap the number of entries to the requested limit" do
      result = call_op(framework_id: @framework_id, limit: 2)
      assert_equal 2, result[:activity].size
    end
  end

  context "as a plain member without collaborator rights" do
    should "be denied" do
      context = AuthorizationContext.new(user: @outsider, tenant_user: @outsider_tu, person: @outsider_person)
      assert_raises(Pundit::NotAuthorizedError) do
        ActsAsTenant.with_tenant(@tenant) do
          Operations::Frameworks::RecentActivity.call(
            context: context, params: { framework_id: @framework_id }
          )
        end
      end
    end
  end
end
