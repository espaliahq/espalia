# frozen_string_literal: true

require "test_helper"

# A past cycle's assessment page: that cycle's ratings, read-only, reached
# by `?cycle_id=` (https://github.com/mr-yum/growth-os/issues/669).
class AssessmentsPastCycleTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @fx = build_role_lens_framework(tenant: @tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @manager_user = create(:user, password: "password123")
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Morgan Manager")
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
      @user = create(:user, password: "password123")
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Alex Assessee", manager: @manager)
      create(:tenant_user, tenant: @tenant, user: @user, person: @person)
      @stranger_user = create(:user, password: "password123")
      create(:tenant_user, tenant: @tenant, user: @stranger_user,
                           person: create(:person, tenant: @tenant, email: @stranger_user.email))
    end
    @assignment, @past_id = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant)
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.rate_as_manager(@person.id, @fx.framework_id, @fx.shared.stable_id,
        level_ordinal: 2, frequency: "some", cycle_id: @past_id, rated_by_id: @manager.id)
    end
  end

  def close_past_cycle
    @open_id = close_and_open_next_role_lens_cycle(@person, @fx, @past_id, tenant: @tenant)
  end

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end

  context "as the manager" do
    setup do
      close_past_cycle
      sign_in(@manager_user)
    end

    should "render the past cycle read-only with its banner" do
      get assessment_path(@assignment, cycle_id: @past_id)

      assert_response :success
      assert_select "##{Views::Assessments::PastCycleBanner::ID}", text: /Q3 2026 closed on .*Alignment didn't start.*Read-only/m
      assert_select "##{Views::Assessments::CycleControl::ID} a[aria-current='page']", text: /Q3 2026/
      assert_select "button", text: /Start alignment/, count: 0
      assert_select "turbo-frame#assessment-matrix[src*='cycle_id=#{@past_id}']"
      assert_select "turbo-frame#assessment-scoring[src*='cycle_id=#{@past_id}']"
    end

    should "serve the past cycle's matrix frame with static pills" do
      get matrix_assessment_path(@assignment, cycle_id: @past_id)

      assert_response :success
      assert_select "form[action*='manager_ratings']", count: 0
    end

    should "keep the open cycle without a cycle_id" do
      get assessment_path(@assignment)

      assert_response :success
      assert_select "##{Views::Assessments::PastCycleBanner::ID}", count: 0
      assert_select "##{Views::Assessments::CycleControl::ID} a[aria-current='page']", text: /Q4 2026/

      get matrix_assessment_path(@assignment)
      assert_select "form[action*='manager_ratings']"
    end

    should "answer 404 for a cycle the person never joined" do
      other = ActsAsTenant.with_tenant(@tenant) do
        create(:assessment_cycle, tenant: @tenant, framework_id: @fx.framework_id, status: "closed")
      end
      get assessment_path(@assignment, cycle_id: other.cycle_id)

      assert_response :not_found
    end
  end

  should "show the assessee their past cycle without the manager's private ratings" do
    close_past_cycle
    sign_in(@user)
    get matrix_assessment_path(@assignment, cycle_id: @past_id)

    assert_response :success
    assert_no_match(/Manager rating/, response.body)
  end

  # The feed spans every cycle; aligning a past one must not open the
  # manager's ratings in the cycle under way.
  should "gate the assessee's feed by the open cycle on a past cycle's page" do
    pd = PersonDevelopment::CommandHandler.new
    ActsAsTenant.with_tenant(@tenant) do
      pd.start_alignment(@person.id, @fx.framework_id, @past_id, started_by_id: @manager.id)
    end
    close_past_cycle
    ActsAsTenant.with_tenant(@tenant) do
      pd.rate_as_manager(@person.id, @fx.framework_id, @fx.shared.stable_id, level_ordinal: 3, frequency: "some",
        cycle_id: @open_id, rated_by_id: @manager.id)
    end
    sign_in(@user)

    get assessment_path(@assignment)
    open_count = css_select("[data-kind='manager_rated']").size
    get assessment_path(@assignment, cycle_id: @past_id)

    assert_equal open_count, css_select("[data-kind='manager_rated']").size
  end

  should "render the past cycle's score that assessments_get reports" do
    pd = PersonDevelopment::CommandHandler.new
    ActsAsTenant.with_tenant(@tenant) do
      [ @fx.shared, @fx.e_only ].product([ 1, 2 ]).each do |capability, ordinal|
        pd.rate_as_manager(@person.id, @fx.framework_id, capability.stable_id, level_ordinal: ordinal,
          frequency: "occasional", cycle_id: @past_id, rated_by_id: @manager.id)
      end
    end
    close_past_cycle
    mcp = ActsAsTenant.with_tenant(@tenant) do
      tenant_user = TenantUser.find_by!(user: @manager_user)
      Operations::Assessments::Get.call(
        context: AuthorizationContext.new(user: @manager_user, tenant_user: tenant_user, person: @manager),
        params: { assignment_id: @assignment.id, cycle_id: @past_id }
      )[:scoring]
    end
    assert mcp[:scored]

    sign_in(@manager_user)
    get scoring_assessment_path(@assignment, cycle_id: @past_id)

    assert_select "#hero-score-bar [role='progressbar'][aria-valuenow='#{mcp[:score]}']"
  end

  should "offer the only cycle once it has closed" do
    ActsAsTenant.with_tenant(@tenant) { AssessmentCycles::CommandHandler.new.close_cycle(@past_id) }
    sign_in(@user)
    get assessment_path(@assignment)

    assert_select "##{Views::Assessments::CycleControl::ID} a[href*='cycle_id=#{@past_id}']", text: /Q3 2026/
  end

  should "refuse someone outside the assessment" do
    close_past_cycle
    sign_in(@stranger_user)
    get assessment_path(@assignment, cycle_id: @past_id)

    assert_redirected_to root_path
  end
end
