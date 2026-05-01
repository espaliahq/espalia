# frozen_string_literal: true

require "test_helper"

class Assessments::MatrixDataBuilderTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant

    framework_id = SecureRandom.uuid_v7
    @framework = create(:framework_state, framework_id: framework_id)
    @role_family = create(:framework_role_family,
      framework_id: framework_id, name: "Engineering")
    @role = create(:framework_role,
      role_family_id: @role_family.role_family_id, name: "Software Engineer",
      code: "E", track: "ic")
    @levels = (1..3).map do |i|
      create(:framework_level,
        role_id: @role.role_id, ordinal: i,
        title: "Engineer #{i}", code: "E#{i}")
    end
    @level = @levels[1] # ordinal 2

    @category = create(:framework_capability_category,
      framework_id: framework_id, name: "Thinking", ordinal: 1)
    @capability = create(:framework_capability,
      category_id: @category.category_id, name: "Strategic Thinking")
    create(:framework_capability_role_binding,
      capability_id: @capability.capability_id, role_id: @role.role_id)
    (1..3).each do |i|
      create(:framework_behavioural_expectation,
        capability_id: @capability.capability_id, level_ordinal: i,
        description: "Level #{i} expectation")
    end

    @person_id = SecureRandom.uuid_v7
    @cycle = create(:assessment_cycle,
      tenant: @tenant, framework_id: framework_id, framework_version: 1)
    @cycle_id = @cycle.cycle_id

    create(:assessment_level_rating,
      tenant: @tenant, person_id: @person_id, framework_id: framework_id,
      cycle_id: @cycle_id, capability_stable_id: @capability.stable_id,
      level_ordinal: 2, self_rated_frequency: "consistent",
      manager_rated_frequency: "occasional", aligned_frequency: "consistent")

    @categories = FrameworkState::CapabilityCategory
      .where(framework_id: framework_id)
      .includes(capabilities: [ :bindings, { expectations: :illustrations } ])
      .order(:ordinal)
  end

  context "context: :self" do
    setup do
      @data = Assessments::MatrixDataBuilder.new(
        framework: @framework, role: @role, level: @level,
        person_id: @person_id, cycle_id: @cycle_id, categories: @categories,
        context: :self
      ).build
    end

    should "expose the assessee's own rating in cells" do
      cell = @data[:categories].first[:capabilities].first[:cells][2]
      assert_equal "consistent", cell[:current_frequency]
    end

    should "scrub manager_frequency from cells" do
      cell = @data[:categories].first[:capabilities].first[:cells][2]
      assert_nil cell[:manager_frequency]
    end

    should "scrub aligned_frequency from cells" do
      cell = @data[:categories].first[:capabilities].first[:cells][2]
      assert_nil cell[:aligned_frequency]
    end

    should "scrub manager_scoring from result" do
      assert_nil @data[:manager_scoring]
    end

    should "scrub aligned_scoring from result" do
      assert_nil @data[:aligned_scoring]
    end

    should "still build self_scoring" do
      assert_not_nil @data[:self_scoring]
    end
  end

  context "context: :manager" do
    setup do
      @data = Assessments::MatrixDataBuilder.new(
        framework: @framework, role: @role, level: @level,
        person_id: @person_id, cycle_id: @cycle_id, categories: @categories,
        context: :manager
      ).build
    end

    should "expose manager_frequency in cells" do
      cell = @data[:categories].first[:capabilities].first[:cells][2]
      assert_equal "occasional", cell[:manager_frequency]
    end

    should "expose self frequency in cells" do
      cell = @data[:categories].first[:capabilities].first[:cells][2]
      assert_equal "consistent", cell[:current_frequency]
    end

    should "expose aligned_frequency in cells" do
      cell = @data[:categories].first[:capabilities].first[:cells][2]
      assert_equal "consistent", cell[:aligned_frequency]
    end

    should "build all perspective scorings" do
      assert_not_nil @data[:self_scoring]
      assert_not_nil @data[:manager_scoring]
      assert_not_nil @data[:aligned_scoring]
    end
  end

  context "context: :alignment" do
    setup do
      @data = Assessments::MatrixDataBuilder.new(
        framework: @framework, role: @role, level: @level,
        person_id: @person_id, cycle_id: @cycle_id, categories: @categories,
        context: :alignment
      ).build
    end

    should "expose all three rating perspectives in cells" do
      cell = @data[:categories].first[:capabilities].first[:cells][2]
      assert_equal "consistent", cell[:current_frequency]
      assert_equal "occasional", cell[:manager_frequency]
      assert_equal "consistent", cell[:aligned_frequency]
    end

    should "build all perspective scorings" do
      assert_not_nil @data[:self_scoring]
      assert_not_nil @data[:manager_scoring]
      assert_not_nil @data[:aligned_scoring]
    end
  end
end
