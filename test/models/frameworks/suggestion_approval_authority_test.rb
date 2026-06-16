# frozen_string_literal: true

require "test_helper"

# The per-viewer approval authority that drives the actionable activity feed.
# Tenant admins approve every tier; collaborators approve per their roles;
# everyone else approves nothing.
class Frameworks::SuggestionApprovalAuthorityTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @framework = create(:framework_state, tenant: @tenant)
    @fwid = @framework.framework_id
    @person = create(:person, tenant: @tenant)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def collaborator(role)
    create(:framework_collaborator, tenant: @tenant, framework_id: @fwid, person_id: @person.id, role: role)
  end

  context "tenant admin" do
    should "approve every tier" do
      authority = Frameworks::SuggestionApprovalAuthority.for(
        framework_id: @fwid, person: nil, tenant_admin: true
      )
      assert authority.can_approve?("role_illustration")     # tier 1
      assert authority.can_approve?("capability")            # tier 2
      assert authority.can_approve?("behavioural_expectation") # tier 3
      assert authority.any?
    end
  end

  context "a capability_lead collaborator" do
    should "approve all three tiers (edit rights + content approve)" do
      collaborator("capability_lead")
      authority = Frameworks::SuggestionApprovalAuthority.for(
        framework_id: @fwid, person: @person, tenant_admin: false
      )
      assert authority.can_approve?("role_illustration")
      assert authority.can_approve?("capability")
      assert authority.can_approve?("behavioural_expectation")
    end
  end

  context "a role_lead collaborator" do
    should "approve tier 1 illustrations but not tier 2/3 content" do
      collaborator("role_lead")
      authority = Frameworks::SuggestionApprovalAuthority.for(
        framework_id: @fwid, person: @person, tenant_admin: false
      )
      assert authority.can_approve?("role_illustration")
      assert_not authority.can_approve?("capability")
      assert_not authority.can_approve?("behavioural_expectation")
    end
  end

  context "a plain collaborator (suggest-only)" do
    should "approve nothing" do
      collaborator("collaborator")
      authority = Frameworks::SuggestionApprovalAuthority.for(
        framework_id: @fwid, person: @person, tenant_admin: false
      )
      assert_not authority.can_approve?("role_illustration")
      assert_not authority.can_approve?("capability")
      assert_not authority.any?
    end
  end

  context "no person, not admin" do
    should "approve nothing" do
      authority = Frameworks::SuggestionApprovalAuthority.for(
        framework_id: @fwid, person: nil, tenant_admin: false
      )
      assert_not authority.any?
    end
  end
end
