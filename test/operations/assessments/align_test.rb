# frozen_string_literal: true

require "test_helper"

# Alignment Operation behaviour: single dispatch (no toggle), only
# available during the `aligning` lifecycle phase, only the manager
# can drive it.
class Operations::Assessments::AlignTest < ActiveSupport::TestCase
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
      @role = role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
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

      # Get into the `aligning` state — required for create_alignment_rating?.
      # Need self + manager ratings first; then manager starts alignment.
      pd_handler.rate_self(@report.id, framework_id, @cap.stable_id,
        level_ordinal: 2, frequency: "some", cycle_id: @cycle_id)
      pd_handler.rate_as_manager(@report.id, framework_id, @cap.stable_id,
        level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id)
      pd_handler.start_alignment(@report.id, framework_id, @cycle_id, started_by_id: @manager.id)

      @framework_id = framework_id
      @report_assignment = PersonFrameworkAssignment.for_person(@report.id).first
    end

    @context = AuthorizationContext.new(user: @manager_user, tenant_user: @tenant_user, person: @manager)
  end

  def call_op(frequency:, comment: nil, capability: @cap)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::Align.call(
        context: @context,
        params: {
          assignment_id: @report_assignment.id,
          capability_stable_id: capability.stable_id,
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

  context "alignment dispatch" do
    should "persist aligned_frequency and return the same payload shape as rate_self/rate_as_manager" do
      result = call_op(frequency: "occasional")
      assert_equal "occasional", reload_rating.aligned_frequency
      assert_equal "occasional", result[:frequency]
      assert_equal @cycle_id,    result[:cycle_id]
      assert_equal @framework_id, result[:framework_id]
      assert_equal @cap.stable_id, result[:capability_stable_id]
      assert_equal 2, result[:level_ordinal]
    end

    should "overwrite (not toggle) when called twice with the same value" do
      call_op(frequency: "occasional")
      result = call_op(frequency: "occasional")
      # Distinct from rate_self/rate_as_manager: align has no untoggle —
      # the value persists rather than clearing.
      assert_equal "occasional", reload_rating.aligned_frequency
      assert_equal "occasional", result[:frequency]
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
          Operations::Assessments::Align.call(
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

  # #606: once a publish retires a capability, its cell takes no agreed value,
  # and the survivor's agreed value lands on the row its ratings moved to.
  context "after a publish during alignment merges a capability into one new to the role" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @survivor = create(:framework_capability, category_id: @cap.category_id, name: "Sound Judgement")
        create(:framework_capability_role_binding, capability_id: @survivor.capability_id, role_id: @role.role_id, weight: 1.0)
        create(:framework_behavioural_expectation, capability_id: @survivor.capability_id, level_ordinal: 2, description: "Weighs")
        @cap.update!(status: "archived")
        PersonDevelopment::CommandHandler.new.migrate_framework_version(@report.id, @framework_id, 1, 2, [
          { from_stable_id: @cap.stable_id, to_stable_id: @survivor.stable_id, mapping_type: "evolved", requires_reassessment: false }
        ])
      end
    end

    should "refuse an agreed value on the retiring capability and record one beside the survivor's carried ratings" do
      assert_raises(Operations::Base::ParameterError) { call_op(frequency: "consistent") }

      call_op(frequency: "consistent", capability: @survivor)

      ActsAsTenant.with_tenant(@tenant) do
        rows = AssessmentLevelRating.across_all_roles.where(person_id: @report.id, level_ordinal: 2)
        assert_equal [ [ @survivor.stable_id, "some", "consistent", "consistent" ] ],
          rows.map { |r| [ r.capability_stable_id, r.self_rated_frequency, r.manager_rated_frequency, r.aligned_frequency ] }
      end
    end
  end
end
