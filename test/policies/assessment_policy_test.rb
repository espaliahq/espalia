# frozen_string_literal: true

require "test_helper"

class AssessmentPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, name: "Developer")
      @manager = create(:person, tenant: @tenant, name: "Manager")
      @person.update!(manager: @manager)

      @framework = create(:framework_state, name: "Test Framework")
      @assignment = create(:person_framework_assignment,
                           tenant: @tenant,
                           person_id: @person.id,
                           framework_id: @framework.framework_id)
    end
  end

  context "as the assigned person" do
    setup do
      @user = create(:user)
      @tenant_user = ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: @user, person: @person)
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
    end

    should "allow show" do
      assert policy.show?
    end

    should "allow matrix" do
      assert policy.matrix?
    end

    should "allow create_self_rating" do
      assert policy.create_self_rating?
    end

    should "deny create_manager_rating" do
      assert_not policy.create_manager_rating?
    end

    should "deny start_alignment (assessee can never start alignment)" do
      assert_not policy.start_alignment?
    end
  end

  context "as the person's manager" do
    setup do
      @user = create(:user)
      @tenant_user = ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: @user, person: @manager)
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @manager)
    end

    should "allow show" do
      assert policy.show?
    end

    should "allow create_manager_rating" do
      assert policy.create_manager_rating?
    end

    should "deny create_self_rating" do
      assert_not policy.create_self_rating?
    end
  end

  context "as an unrelated person" do
    setup do
      @user = create(:user)
      @other_person = ActsAsTenant.with_tenant(@tenant) do
        p = create(:person, tenant: @tenant, name: "Other")
        @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: p)
        p
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @other_person)
    end

    should "deny show" do
      assert_not policy.show?
    end

    should "deny create_self_rating" do
      assert_not policy.create_self_rating?
    end

    should "deny create_manager_rating" do
      assert_not policy.create_manager_rating?
    end

    should "deny create_alignment_rating" do
      assert_not policy.create_alignment_rating?
    end

    should "deny view_alignment" do
      assert_not policy.view_alignment?
    end

    should "deny start_alignment" do
      assert_not policy.start_alignment?
    end
  end

  context "with no person linked" do
    setup do
      @user = create(:user)
      @tenant_user = ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: @user)
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: nil)
    end

    should "deny all actions" do
      assert_not policy.index?
      assert_not policy.show?
      assert_not policy.create_self_rating?
      assert_not policy.create_manager_rating?
      assert_not policy.create_alignment_rating?
      assert_not policy.view_alignment?
      assert_not policy.start_alignment?
    end
  end

  # ── Cycle-state-aware predicates ──
  #
  # create_self_rating?, create_manager_rating?, create_alignment_rating?,
  # view_alignment?, and start_alignment? all depend on the participant's
  # status in the current open cycle. These contexts cover the lifecycle.

  context "with an open cycle in :enrolled state (no ratings yet)" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework.framework_id)
        create(:assessment_cycle_enrollment, tenant: @tenant, cycle: cycle,
          person_id: @person.id, status: "enrolled")
      end
    end

    should "deny manager start_alignment until at least one rating exists" do
      assert_not AssessmentPolicy.new(manager_context, @assignment).start_alignment?
    end
  end

  context "with an open cycle in :started state" do
    setup do
      @cycle = ActsAsTenant.with_tenant(@tenant) do
        cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework.framework_id)
        create(:assessment_cycle_enrollment, tenant: @tenant, cycle: cycle,
          person_id: @person.id, status: "enrolled")
        create(:assessment_cycle_progress, tenant: @tenant, cycle: cycle,
          person_id: @person.id, status: "started", started_at: Time.current)
        cycle
      end
      @manager_ctx = manager_context
    end

    should "allow manager to start alignment" do
      assert AssessmentPolicy.new(@manager_ctx, @assignment).start_alignment?
    end

    should "deny assessee from starting alignment" do
      assert_not AssessmentPolicy.new(assessee_context, @assignment).start_alignment?
    end

    should "allow assessee to record self ratings (not yet frozen)" do
      assert AssessmentPolicy.new(assessee_context, @assignment).create_self_rating?
    end

    should "deny alignment ratings before alignment is started" do
      assert_not AssessmentPolicy.new(@manager_ctx, @assignment).create_alignment_rating?
      assert_not AssessmentPolicy.new(assessee_context, @assignment).create_alignment_rating?
    end

    should "deny view_alignment for both parties before alignment starts" do
      assert_not AssessmentPolicy.new(@manager_ctx, @assignment).view_alignment?
      assert_not AssessmentPolicy.new(assessee_context, @assignment).view_alignment?
    end
  end

  context "with an open cycle in :aligning state" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework.framework_id)
        create(:assessment_cycle_enrollment, tenant: @tenant, cycle: cycle,
          person_id: @person.id, status: "enrolled")
        create(:assessment_cycle_progress, tenant: @tenant, cycle: cycle,
          person_id: @person.id, status: "aligning", started_at: 1.day.ago,
          alignment_started_at: Time.current, alignment_started_by_id: @manager.id)
      end
    end

    should "freeze self rating for assessee" do
      assert_not AssessmentPolicy.new(assessee_context, @assignment).create_self_rating?
    end

    should "freeze manager rating" do
      assert_not AssessmentPolicy.new(manager_context, @assignment).create_manager_rating?
    end

    should "allow alignment ratings from both parties" do
      assert AssessmentPolicy.new(assessee_context, @assignment).create_alignment_rating?
      assert AssessmentPolicy.new(manager_context, @assignment).create_alignment_rating?
    end

    should "deny start_alignment (already started)" do
      assert_not AssessmentPolicy.new(manager_context, @assignment).start_alignment?
    end

    should "allow manager to complete alignment" do
      assert AssessmentPolicy.new(manager_context, @assignment).complete_alignment?
    end

    should "deny assessee from completing alignment" do
      assert_not AssessmentPolicy.new(assessee_context, @assignment).complete_alignment?
    end

    should "allow view_alignment for both parties" do
      assert AssessmentPolicy.new(manager_context, @assignment).view_alignment?
      assert AssessmentPolicy.new(assessee_context, @assignment).view_alignment?
    end
  end

  context "with an open cycle in :aligned state" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework.framework_id)
        create(:assessment_cycle_enrollment, tenant: @tenant, cycle: cycle,
          person_id: @person.id, status: "enrolled")
        create(:assessment_cycle_progress, tenant: @tenant, cycle: cycle,
          person_id: @person.id, status: "aligned", started_at: 1.day.ago,
          aligned_at: Time.current)
      end
    end

    should "freeze self and manager ratings" do
      assert_not AssessmentPolicy.new(assessee_context, @assignment).create_self_rating?
      assert_not AssessmentPolicy.new(manager_context, @assignment).create_manager_rating?
    end

    should "deny alignment ratings (alignment is complete)" do
      assert_not AssessmentPolicy.new(assessee_context, @assignment).create_alignment_rating?
      assert_not AssessmentPolicy.new(manager_context, @assignment).create_alignment_rating?
    end

    should "still view_alignment after completion (aligned values are the canonical view)" do
      assert AssessmentPolicy.new(assessee_context, @assignment).view_alignment?
      assert AssessmentPolicy.new(manager_context, @assignment).view_alignment?
    end

    should "deny start_alignment" do
      assert_not AssessmentPolicy.new(manager_context, @assignment).start_alignment?
    end

    should "deny complete_alignment (already completed)" do
      assert_not AssessmentPolicy.new(manager_context, @assignment).complete_alignment?
    end
  end

  private

  def policy
    AssessmentPolicy.new(@ctx, @assignment)
  end

  def assessee_context
    user = create(:user)
    tu = ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: user, person: @person)
    end
    AuthorizationContext.new(user: user, tenant_user: tu, person: @person)
  end

  def manager_context
    user = create(:user)
    tu = ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: user, person: @manager)
    end
    AuthorizationContext.new(user: user, tenant_user: tu, person: @manager)
  end
end
