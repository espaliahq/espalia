# frozen_string_literal: true

require "test_helper"

class Assessments::LevelCoverageTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant

    @framework_id = SecureRandom.uuid_v7
    create(:framework_state, framework_id: @framework_id)
    role_family = create(:framework_role_family, framework_id: @framework_id, name: "Engineering")
    @role = create(:framework_role, role_family_id: role_family.role_family_id,
      name: "Software Engineer", code: "E", track: "ic")
    @levels = (1..3).map do |i|
      create(:framework_level, role_id: @role.role_id, ordinal: i, title: "Engineer #{i}", code: "E#{i}")
    end
    @category = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)

    # Two capabilities, both bound to the role, each with an expectation at L1+L2.
    @cap1 = build_capability("Critical Thinking")
    @cap2 = build_capability("Problem Solving")

    @person_id = SecureRandom.uuid_v7
    # Assigned at L2 (ordinal 2).
    @assignment = create(:person_framework_assignment,
      tenant: @tenant, person_id: @person_id, framework_id: @framework_id,
      role_id: @role.role_id, level_id: @levels[1].level_id)
    @cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id, framework_version: 1)
    @cycle_id = @cycle.cycle_id
  end

  teardown { ActsAsTenant.current_tenant = nil }

  context "#call" do
    should "report no side complete when nothing is rated" do
      result = coverage
      assert_equal 2, result[:total]
      assert_not result[:self_complete]
      assert_not result[:manager_complete]
      assert_not result[:aligned_complete]
    end

    should "stay incomplete while only some current-level cells are rated" do
      rate(@cap1, self_rated_frequency: "consistent")
      assert_not coverage[:self_complete]
      assert_equal 1, coverage[:self_rated]
    end

    should "be self-complete once every current-level cell has a self rating" do
      rate(@cap1, self_rated_frequency: "consistent")
      rate(@cap2, self_rated_frequency: "some")
      assert coverage[:self_complete]
      assert_not coverage[:manager_complete], "manager side untouched"
    end

    should "track each side independently" do
      rate(@cap1, self_rated_frequency: "consistent", manager_rated_frequency: "consistent")
      rate(@cap2, self_rated_frequency: "some")
      assert coverage[:self_complete]
      assert_not coverage[:manager_complete]
    end

    should "be complete for both sides when both are fully rated" do
      rate(@cap1, self_rated_frequency: "consistent", manager_rated_frequency: "occasional")
      rate(@cap2, self_rated_frequency: "some", manager_rated_frequency: "none")
      assert coverage[:self_complete]
      assert coverage[:manager_complete]
    end

    should "track the aligned perspective independently of self and manager" do
      rate(@cap1, self_rated_frequency: "consistent", manager_rated_frequency: "consistent",
        aligned_frequency: "consistent")
      rate(@cap2, self_rated_frequency: "some", manager_rated_frequency: "some")

      result = coverage
      assert_equal 1, result[:aligned_rated]
      assert_not result[:aligned_complete]
      assert result[:self_complete]
    end

    should "be aligned-complete once every current-level cell carries an agreed value" do
      rate(@cap1, aligned_frequency: "consistent")
      rate(@cap2, aligned_frequency: "some")

      result = coverage
      assert result[:aligned_complete]
      assert_equal 2, result[:aligned_rated]
      assert_not result[:self_complete], "self side untouched"
    end

    should "never be complete when the assessed level has no cells" do
      # Move the assignment to L3 ordinal — no expectations exist there.
      no_cell_level = @levels[2]
      @assignment.update!(level_id: no_cell_level.level_id)
      # Expectations were created at ordinals 1 and 2 only.
      result = coverage
      assert_equal 0, result[:total]
      assert_not result[:self_complete]
    end

    should "prefer the enrollment snapshot level over the assignment level" do
      # Promote the assignment to L3 (no cells) but snapshot says they were
      # assessed at L2 — coverage must score against L2.
      @assignment.update!(level_id: @levels[2].level_id)
      AssessmentCycleEnrollment.create!(
        tenant: @tenant, cycle_id: @cycle_id, person_id: @person_id,
        status: "enrolled", enrolled_at: Time.current,
        role_id: @role.role_id, level_id: @levels[1].level_id, level_ordinal: 2
      )
      assert_equal 2, coverage[:total]
    end
  end

  context "agreement with MatrixDataBuilder" do
    should "match the builder's current_level_complete for the self perspective" do
      rate(@cap1, self_rated_frequency: "consistent")
      rate(@cap2, self_rated_frequency: "some")

      categories = FrameworkState::CapabilityCategory
        .where(framework_id: @framework_id)
        .includes(capabilities: [ :bindings, { expectations: :illustrations } ])
        .order(:ordinal)
      built = Assessments::MatrixDataBuilder.new(
        framework: FrameworkState::Framework.find_by(framework_id: @framework_id),
        role: @role, level: @levels[1], person_id: @person_id,
        cycle_id: @cycle_id, categories: categories, context: :self
      ).build

      assert_equal built[:current_level_complete], coverage[:self_complete]
    end
  end

  private

  def coverage
    Assessments::LevelCoverage.new(
      person_id: @person_id, framework_id: @framework_id, cycle_id: @cycle_id
    ).call
  end

  def build_capability(name)
    cap = create(:framework_capability, category_id: @category.category_id, name: name)
    create(:framework_capability_role_binding, capability_id: cap.capability_id, role_id: @role.role_id)
    (1..2).each do |i|
      create(:framework_behavioural_expectation, capability_id: cap.capability_id,
        level_ordinal: i, description: "#{name} L#{i}")
    end
    cap
  end

  def rate(capability, **frequencies)
    create(:assessment_level_rating,
      tenant: @tenant, person_id: @person_id, framework_id: @framework_id,
      cycle_id: @cycle_id, capability_stable_id: capability.stable_id,
      level_ordinal: 2, **frequencies)
  end
end
