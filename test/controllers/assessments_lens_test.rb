# frozen_string_literal: true

require "test_helper"

# Reading an assessment through another role or level (ADR-22): the four
# read endpoints take `as_role` / `as_level`, a pair the framework doesn't
# have is a 404, and the assessee never receives a manager rating on a cell
# only the lens role reads.
class AssessmentsLensTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @fx = build_role_lens_framework(tenant: @tenant)
    @user = create(:user, password: "password123")
    @manager_user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Morgan Manager")
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Alex Assessee", manager: @manager)
      create(:tenant_user, tenant: @tenant, user: @user, person: @person)
    end
    @assignment, @cycle_id = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant)
    @pm_lens = { as_role: @fx.pm.role_id, as_level: 2 }
  end

  context "the read endpoints" do
    setup { sign_in @user }

    should "render the page against another role" do
      get assessment_path(@assignment, @pm_lens)

      assert_response :success
      assert_includes response.body, "Roadmapping"
      assert_not_includes response.body, "Systems Design"
      assert_equal "PM2", matrix_data[:lens].code
    end

    should "render another level of the home ladder" do
      get assessment_path(@assignment, as_level: 3)

      assert_response :success
      assert_equal 3, matrix_data[:person_level]
      assert_equal 2, matrix_data[:home_level]
    end

    should "carry the lens on every frame src" do
      get assessment_path(@assignment, @pm_lens)

      frames = response.parsed_body.css("turbo-frame[src]").to_h { |f| [ f["id"], f["src"] ] }
      %w[assessment-scoring assessment-matrix assessment-activity].each do |id|
        assert_includes frames.fetch(id), "as_role=#{@fx.pm.role_id}", "#{id} dropped the lens"
        assert_includes frames.fetch(id), "as_level=2", "#{id} dropped the lens"
      end
    end

    should "serve the matrix, scoring and activity frames against the lens" do
      get matrix_assessment_path(@assignment, @pm_lens)
      assert_response :success
      assert_includes response.body, "Roadmapping"

      get scoring_assessment_path(@assignment, @pm_lens)
      assert_response :success
      assert_equal "PM2", matrix_data[:lens].code

      get assessment_activity_path(@assignment, @pm_lens)
      assert_response :success
    end

    should "answer 404 for a level or role the framework doesn't have" do
      get assessment_path(@assignment, as_level: 9)
      assert_response :not_found

      get matrix_assessment_path(@assignment, as_role: SecureRandom.uuid_v7, as_level: 2)
      assert_response :not_found

      get assessment_activity_path(@assignment, as_level: "E3")
      assert_response :not_found
    end
  end

  context "a viewer with no access" do
    should "be denied before the lens is read" do
      stranger = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        person = create(:person, tenant: @tenant, email: stranger.email)
        create(:tenant_user, tenant: @tenant, user: stranger, person: person)
      end
      sign_in stranger

      get assessment_path(@assignment, as_level: 9)
      assert_response :redirect
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end

  context "manager ratings under a lens" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        [ @fx.shared, @fx.pm_only ].each do |capability|
          create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle_id, person_id: @person.id,
            framework_id: @fx.framework_id, capability_stable_id: capability.stable_id, level_ordinal: 2,
            self_rated_frequency: "some", manager_rated_frequency: "consistent", aligned_frequency: "occasional")
        end
        AssessmentCycleProgress.find_by!(cycle_id: @cycle_id, person_id: @person.id).update!(status: "aligned")
      end
    end

    should "stay private on cells only the lens role reads, even once home alignment is done" do
      sign_in @user
      get assessment_path(@assignment, @pm_lens)

      assert_response :success
      assert_equal :self, controller.send(:assessment_context)
      pm_only = cell(@fx.pm_only)
      assert_nil pm_only[:manager_frequency]
      assert_nil pm_only[:aligned_frequency]
      assert_not pm_only[:in_home_scope]

      shared = cell(@fx.shared)
      assert_equal "consistent", shared[:manager_frequency], "home alignment disclosed the shared cell"
      assert_equal "occasional", shared[:aligned_frequency]
      assert_nil matrix_data[:manager_scoring]
    end

    should "read as alignment on the home role, where every cell is the record" do
      sign_in @user
      get assessment_path(@assignment, as_level: 3)

      assert_equal :alignment, controller.send(:assessment_context)
    end

    should "show the manager every cell, and no alignment controls under another role" do
      sign_in @manager_user
      get assessment_path(@assignment, @pm_lens)

      assert_response :success
      assert_equal :manager, controller.send(:assessment_context)
      assert_equal "consistent", cell(@fx.pm_only)[:manager_frequency]
      assert_not_includes response.body, "Re-open alignment"
    end
  end

  private

  def matrix_data
    controller.instance_variable_get(:@matrix_data)
  end

  def cell(capability, ordinal: 2)
    matrix_data[:categories].flat_map { |c| c[:capabilities] }
      .find { |cap| cap[:capability].capability_id == capability.capability_id }
      .fetch(:cells).fetch(ordinal)
  end

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end
