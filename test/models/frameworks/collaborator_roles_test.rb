# frozen_string_literal: true

require "test_helper"

# The viewer's collaborator roles, loaded once and answered in memory (#383).
#
# Roles are additive — a person holding two roles gets the union of their
# rights — so every predicate here is asserted against the union, not just
# against a single role.
class Frameworks::CollaboratorRolesTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @framework_id = SecureRandom.uuid_v7
    @person = create(:person, tenant: @tenant)
  end

  context ".load" do
    should "read the person's roles on this framework in one query" do
      create(:framework_collaborator, tenant: @tenant, framework_id: @framework_id,
             person_id: @person.id, role: "editor")

      roles = nil
      assert_queries_count(1) do
        roles = Frameworks::CollaboratorRoles.load(framework_id: @framework_id, person_id: @person.id)
      end

      # Every predicate is answered from the rows already loaded.
      assert_queries_count(0) do
        assert_predicate roles, :any?
        assert_predicate roles, :can_suggest?
        assert_predicate roles, :can_edit?
        assert_predicate roles, :can_publish?
        assert_predicate roles, :can_approve_content?
        assert_not roles.owner?
      end
    end

    should "not query at all for a user with no Person" do
      assert_queries_count(0) do
        roles = Frameworks::CollaboratorRoles.load(framework_id: @framework_id, person_id: nil)

        assert_not roles.any?
      end
    end

    should "ignore roles held on another framework" do
      create(:framework_collaborator, tenant: @tenant, framework_id: SecureRandom.uuid_v7,
             person_id: @person.id, role: "owner")

      assert_not Frameworks::CollaboratorRoles
        .load(framework_id: @framework_id, person_id: @person.id).any?
    end

    should "ignore another person's roles on this framework" do
      create(:framework_collaborator, tenant: @tenant, framework_id: @framework_id,
             person_id: create(:person, tenant: @tenant).id, role: "owner")

      assert_not Frameworks::CollaboratorRoles
        .load(framework_id: @framework_id, person_id: @person.id).any?
    end
  end

  context "rights per role" do
    should "give a viewer presence but no rights" do
      roles = build_roles("viewer")

      assert_predicate roles, :any?
      assert_not roles.can_suggest?
      assert_not roles.can_edit?
      assert_not roles.can_publish?
      assert_not roles.can_approve_content?
    end

    should "let a collaborator suggest but not edit structure" do
      roles = build_roles("collaborator")

      assert_predicate roles, :can_suggest?
      assert_not roles.can_edit?
    end

    should "let a lead edit but not publish or approve content" do
      roles = build_roles("role_lead")

      assert_predicate roles, :can_edit?
      assert_not roles.can_publish?
      assert_not roles.can_approve_content?
    end

    should "let a capability lead approve content but not publish" do
      roles = build_roles("capability_lead")

      assert_predicate roles, :can_approve_content?
      assert_not roles.can_publish?
    end

    should "give an owner everything, including collaborator management" do
      roles = build_roles("owner")

      assert_predicate roles, :can_publish?
      assert_predicate roles, :owner?
    end

    should "union the rights of several roles held at once" do
      # Neither role alone can both publish and lead a role; together they do
      # the union — additive, never subtractive.
      roles = build_roles("role_lead", "editor")

      assert_predicate roles, :can_edit?
      assert_predicate roles, :can_publish?
      assert_not roles.owner?
    end

    should "answer nothing for a viewer with no roles at all" do
      roles = Frameworks::CollaboratorRoles.none

      assert_not roles.any?
      assert_not roles.can_suggest?
      assert_not roles.owner?
    end
  end

  private

  def build_roles(*roles)
    Frameworks::CollaboratorRoles.new(roles)
  end
end
