# frozen_string_literal: true

require "test_helper"

# Mirrors rate_self_test for the manager-rating Operation:
# - dispatches to the right command per existing state (rate / revise / clear)
# - persists onto the same AssessmentLevelRating row (manager_rated_frequency)
# - emits the right event with audit metadata
# - denies non-managers
class Operations::Assessments::RateAsManagerTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @manager_user = create(:user)
    @report_user  = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Mgr")
      @report  = create(:person, tenant: @tenant, manager_id: @manager.id, email: @report_user.email, name: "Rep")
      @tenant_user = create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager, role: :member)

      framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: framework_id, name: "Eng")
      role  = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")
      cat = create(:framework_capability_category, framework_id: framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding,
        capability_id: @cap.capability_id, role_id: role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 2, description: "Synthesises")

      pd_handler = PersonDevelopment::CommandHandler.new
      cycles_handler = AssessmentCycles::CommandHandler.new
      pd_handler.assign_to_framework(@report.id, framework_id, role.role_id, level.level_id)

      @cycle_id = SecureRandom.uuid_v7
      cycles_handler.define_cycle(@cycle_id, framework_id, "Q1", "regular", 1, defined_by: @manager.id)
      cycles_handler.enroll(@cycle_id, @report.id, enrolled_by: @manager.id)

      @framework_id = framework_id
      @report_assignment = PersonFrameworkAssignment.for_person(@report.id).first
    end

    @context = AuthorizationContext.new(user: @manager_user, tenant_user: @tenant_user, person: @manager)
  end

  def call_op(frequency:, comment: nil)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::RateAsManager.call(
        context: @context,
        params: {
          assignment_id: @report_assignment.id,
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          frequency: frequency,
          comment: comment
        }
      )
    end
  end

  def reload_rating
    ActsAsTenant.with_tenant(@tenant) do
      AssessmentLevelRating.find_by(
        cycle_id: @cycle_id, person_id: @report.id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2
      )
    end
  end

  context "first rating" do
    should "persist manager_rated_frequency on the projection" do
      result = call_op(frequency: "consistent")
      assert_equal "consistent", reload_rating.manager_rated_frequency
      assert_equal "consistent", result[:frequency]
      assert_equal @cycle_id,    result[:cycle_id]
      assert_equal @framework_id, result[:framework_id]
    end
  end

  context "second rating with the SAME frequency" do
    should "clear the rating (toggle off) — same semantics as rate_self" do
      call_op(frequency: "consistent")
      result = call_op(frequency: "consistent")
      assert_nil reload_rating&.manager_rated_frequency
      assert_nil result[:frequency]
    end
  end

  context "second rating with a different frequency" do
    should "revise" do
      call_op(frequency: "some")
      call_op(frequency: "consistent")
      assert_equal "consistent", reload_rating.manager_rated_frequency
    end
  end

  context "policy" do
    should "deny a non-manager caller" do
      stranger_user = create(:user)
      ActsAsTenant.with_tenant(@tenant) do
        stranger_person = create(:person, tenant: @tenant, email: stranger_user.email)
        tu = create(:tenant_user, tenant: @tenant, user: stranger_user, person: stranger_person, role: :member)
        ctx = AuthorizationContext.new(user: stranger_user, tenant_user: tu, person: stranger_person)
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Assessments::RateAsManager.call(
            context: ctx,
            params: {
              assignment_id: @report_assignment.id,
              capability_stable_id: @cap.stable_id,
              level_ordinal: 2, frequency: "consistent"
            }
          )
        end
      end
    end
  end

  context "audit metadata" do
    should "stamp acting_via on the ManagerRated event" do
      observed = nil
      handler = ->(e) { observed = e.metadata.to_h }

      Rails.configuration.event_store
        .within do
          AuditMetadata.with(acting_via: :mcp, client_application_id: "app-xyz") do
            call_op(frequency: "consistent")
          end
        end
        .subscribe(handler, to: [ PersonDevelopment::Events::ManagerRated ])
        .call

      assert observed, "expected ManagerRated event to be published"
      assert_equal "mcp",     observed[:acting_via]
      assert_equal "app-xyz", observed[:client_application_id]
    end
  end
end
