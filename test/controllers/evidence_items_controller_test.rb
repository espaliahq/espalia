# frozen_string_literal: true

require "test_helper"

class EvidenceItemsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @author_user = create(:user, password: "password123")
    @other_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @author = create(:person, tenant: @tenant, email: @author_user.email, name: "Author")
      @other = create(:person, tenant: @tenant, email: @other_user.email, name: "Other")
      create(:tenant_user, tenant: @tenant, user: @author_user, person: @author, role: :member)
      create(:tenant_user, tenant: @tenant, user: @other_user, person: @other, role: :member)

      framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: framework_id, name: "Eng")
      role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")
      cat = create(:framework_capability_category, framework_id: framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding, capability_id: @cap.capability_id, role_id: role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation, capability_id: @cap.capability_id, level_ordinal: 2, description: "x")

      handler = PersonDevelopment::CommandHandler.new
      handler.assign_to_framework(@author.id, framework_id, role.role_id, level.level_id)
      @evidence_id = SecureRandom.uuid_v7
      handler.record_evidence(@author.id, framework_id, @evidence_id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2, source: "self",
        evidence_type: "project_outcome", content: "Original content", author_id: @author.id)
    end
  end

  context "GET /evidence (authored section)" do
    should "list the author's evidence with edit + withdraw affordances" do
      sign_in @author_user
      get evidence_hub_path
      assert_response :success
      assert_match "Evidence you&#39;ve provided", response.body
      assert_match "Original content", response.body
      assert_select "form[action=?]", evidence_item_path(@evidence_id)
    end
  end

  context "PATCH /evidence_items/:id" do
    should "let the author edit their evidence" do
      sign_in @author_user
      cell = "#{@cap.stable_id}|2"
      patch evidence_item_path(@evidence_id), params: { return_to: "hub", evidence: {
        evidence_id: @evidence_id, primary_cell: cell, desired_links: [ cell ],
        evidence_type: "project_outcome", content: "Revised content", title: "Now titled"
      } }
      assert_redirected_to evidence_hub_path
      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(@evidence_id)
        assert_equal "Revised content", item.content
        assert_equal "Now titled", item.title
      end
    end

    should "deny a non-author" do
      sign_in @other_user
      cell = "#{@cap.stable_id}|2"
      patch evidence_item_path(@evidence_id), params: { return_to: "hub", evidence: {
        evidence_id: @evidence_id, primary_cell: cell, desired_links: [ cell ],
        evidence_type: "project_outcome", content: "Hijacked"
      } }
      assert_redirected_to root_path
      ActsAsTenant.with_tenant(@tenant) { assert_equal "Original content", EvidenceItem.find(@evidence_id).content }
    end
  end

  context "DELETE /evidence_items/:id (withdraw)" do
    should "let the author withdraw their evidence" do
      sign_in @author_user
      delete evidence_item_path(@evidence_id)
      assert_redirected_to evidence_hub_path
      ActsAsTenant.with_tenant(@tenant) { assert_equal "withdrawn", EvidenceItem.find(@evidence_id).link_status }
    end

    should "deny a non-author non-admin" do
      sign_in @other_user
      delete evidence_item_path(@evidence_id)
      assert_redirected_to root_path
      ActsAsTenant.with_tenant(@tenant) { assert_equal "active", EvidenceItem.find(@evidence_id).link_status }
    end
  end
end
