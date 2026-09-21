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

    # Self / manager / aligned each get a distinct frequency so that any
    # fallback-chain leak (aligned → manager → self) is detectable in scoring.
    create(:assessment_level_rating,
      tenant: @tenant, person_id: @person_id, framework_id: framework_id,
      cycle_id: @cycle_id, capability_stable_id: @capability.stable_id,
      level_ordinal: 2, self_rated_frequency: "consistent",
      manager_rated_frequency: "occasional", aligned_frequency: "none")

    @categories = FrameworkState::CapabilityCategory
      .where(framework_id: framework_id)
      .includes(capabilities: [ :bindings, { expectations: :illustrations } ])
      .order(:ordinal)
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  def first_capability
    build_self_data[:categories].first[:capabilities].first
  end

  context "required (resolved tolerance of 0)" do
    # Mirrors the engine's own resolution — binding, then category, then the
    # framework default — so the card's chip and the block gate agree.
    should "be false when nothing sets a zero tolerance" do
      assert_equal false, first_capability[:required]
      assert_equal 1.0, first_capability[:weight]
    end

    should "be true when the binding's own tolerance is 0" do
      FrameworkState::CapabilityRoleBinding.find_by!(capability_id: @capability.capability_id)
        .update!(deficit_threshold: 0, weight: 2.0)
      assert_equal true, first_capability[:required]
      assert_equal 2.0, first_capability[:weight]
    end

    should "inherit a zero tolerance from the category" do
      @category.update!(deficit_threshold: 0)
      assert_equal true, first_capability[:required]
    end

    should "let a binding's own tolerance override the category's zero" do
      @category.update!(deficit_threshold: 0)
      FrameworkState::CapabilityRoleBinding.find_by!(capability_id: @capability.capability_id)
        .update!(deficit_threshold: 0.5)
      assert_equal false, first_capability[:required]
    end
  end

  context "context validation" do
    should "raise ArgumentError on unknown context values" do
      assert_raises(ArgumentError) do
        Assessments::MatrixDataBuilder.new(
          framework: @framework, role: @role, level: @level,
          person_id: @person_id, cycle_id: @cycle_id, categories: @categories,
          context: :selff
        ).build
      end
    end
  end

  context "assessment level snapshot (per-cycle)" do
    should "score against the enrollment snapshot level, not the passed (current) level" do
      # Passed @level is ordinal 2; snapshot says they were assessed at ordinal 1.
      build_snapshot_enrollment(role_id: @role.role_id, level_id: @levels[0].level_id, level_ordinal: 1)
      data = build_self_data
      assert_equal 1, data[:person_level]
      assert_equal 1, data[:level].ordinal
    end

    should "ignore a snapshot whose role differs from the rendered role" do
      build_snapshot_enrollment(role_id: SecureRandom.uuid_v7, level_id: @levels[0].level_id, level_ordinal: 1)
      assert_equal 2, build_self_data[:person_level], "cross-role snapshot must not apply"
    end

    should "fall back to the passed level when no snapshot exists" do
      assert_equal 2, build_self_data[:person_level]
    end
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

    should "force effective scoring to match self-only (no fallback leak)" do
      # The fallback chain (aligned → manager → self) would otherwise produce
      # different totals than self-only when aligned and manager carry data.
      # In :self context the primary perspective is forced to :self_only so
      # effective scoring cannot leak manager- or aligned-derived numbers.
      assert_equal @data[:self_scoring][:performance_ratio],
                   @data[:scoring][:performance_ratio]
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
      assert_equal "none", cell[:aligned_frequency]
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
      assert_equal "none", cell[:aligned_frequency]
    end

    should "build all perspective scorings" do
      assert_not_nil @data[:self_scoring]
      assert_not_nil @data[:manager_scoring]
      assert_not_nil @data[:aligned_scoring]
    end
  end

  context "evidence loading" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @assessee = create(:person, tenant: @tenant)
        @manager = create(:person, tenant: @tenant)
        @peer = create(:person, tenant: @tenant)
        # Two pieces of evidence at the same coordinate; one elsewhere.
        @ev_self = create(:evidence_item, tenant: @tenant,
          person_id: @assessee.id, framework_id: @framework.framework_id,
          capability_stable_id: @capability.stable_id, level_ordinal: 2,
          author: @assessee, source: "self", evidence_type: "project_outcome",
          content: "Shipped X")
        @ev_mgr = create(:evidence_item, tenant: @tenant,
          person_id: @assessee.id, framework_id: @framework.framework_id,
          capability_stable_id: @capability.stable_id, level_ordinal: 2,
          author: @manager, source: "manager", evidence_type: "code_review",
          content: "Strong PR")
        @ev_peer_other = create(:evidence_item, tenant: @tenant,
          person_id: @assessee.id, framework_id: @framework.framework_id,
          capability_stable_id: @capability.stable_id, level_ordinal: 3,
          author: @peer, source: "peer", evidence_type: "peer_feedback",
          content: "Helpful")
        # Withdrawn evidence should be excluded.
        create(:evidence_item, tenant: @tenant,
          person_id: @assessee.id, framework_id: @framework.framework_id,
          capability_stable_id: @capability.stable_id, level_ordinal: 2,
          author: @manager, source: "manager", evidence_type: "code_review",
          content: "Old", link_status: "withdrawn")
      end
    end

    should "expose all active evidence to a viewer who sees all" do
      data = build_for(viewer_person_id: @manager.id, viewer_sees_all_evidence: true)
      cell = data[:categories].first[:capabilities].first[:cells][2]
      assert_equal 2, cell[:evidence_count]
      assert_equal [ @ev_self.id, @ev_mgr.id ].sort, cell[:evidence].map(&:id).sort
    end

    should "filter to viewer's own contributions when not in chain" do
      data = build_for(viewer_person_id: @peer.id, viewer_sees_all_evidence: false)
      cell = data[:categories].first[:capabilities].first[:cells][2]
      assert_equal 0, cell[:evidence_count]
      cell3 = data[:categories].first[:capabilities].first[:cells][3]
      assert_equal 1, cell3[:evidence_count]
      assert_equal @ev_peer_other.id, cell3[:evidence].first.id
    end

    should "return no evidence when viewer_person_id is nil" do
      data = build_for(viewer_person_id: nil, viewer_sees_all_evidence: false)
      cell = data[:categories].first[:capabilities].first[:cells][2]
      assert_equal 0, cell[:evidence_count]
    end

    should "exclude withdrawn evidence" do
      data = build_for(viewer_person_id: @manager.id, viewer_sees_all_evidence: true)
      cell = data[:categories].first[:capabilities].first[:cells][2]
      assert_not_includes cell[:evidence].map(&:link_status), "withdrawn"
    end
  end

  context "current-level completion" do
    setup do
      # A second current-level capability that starts unrated, so the role is
      # not yet complete. (@capability is already rated at ordinal 2 in setup.)
      @capability2 = create(:framework_capability,
        category_id: @category.category_id, name: "Delivery")
      create(:framework_capability_role_binding,
        capability_id: @capability2.capability_id, role_id: @role.role_id)
      (1..3).each do |i|
        create(:framework_behavioural_expectation,
          capability_id: @capability2.capability_id, level_ordinal: i,
          description: "Delivery L#{i}")
      end
      @categories = FrameworkState::CapabilityCategory
        .where(framework_id: @framework.framework_id)
        .includes(capabilities: [ :bindings, { expectations: :illustrations } ])
        .order(:ordinal)
    end

    should "be false while a current-level cell is unrated (:self)" do
      assert_not build_completion(:self)[:current_level_complete]
    end

    should "be true once every current-level cell is rated (:self)" do
      rate_capability2(self_rated_frequency: "some")
      assert build_completion(:self)[:current_level_complete]
    end

    should "key off the active context's perspective" do
      # Only a self rating is added for the second capability.
      rate_capability2(self_rated_frequency: "some")
      assert build_completion(:self)[:current_level_complete]
      # Manager perspective is still missing the second capability's rating.
      assert_not build_completion(:manager)[:current_level_complete]
    end

    should "be false while a current-level cell is only carried forward (unvetted)" do
      # Values exist on every current-level cell, but this one is carried —
      # Complete means vetted this cycle, so the pill must stay In Progress.
      rate_capability2(self_rated_frequency: "some", self_rating_source: "seeded")
      assert_not build_completion(:self)[:current_level_complete]

      # Confirming it (human provenance) completes the level.
      AssessmentLevelRating.find_by!(
        cycle_id: @cycle_id, person_id: @person_id,
        capability_stable_id: @capability2.stable_id, level_ordinal: 2
      ).update!(self_rating_source: "human")
      assert build_completion(:self)[:current_level_complete]
    end

    should "be false when the current level has no cells" do
      empty_level = create(:framework_level,
        role_id: @role.role_id, ordinal: 4, title: "Engineer 4", code: "E4")
      assert_not build_completion(:self, level: empty_level)[:current_level_complete]
    end
  end

  private

  def rate_capability2(**frequencies)
    create(:assessment_level_rating,
      tenant: @tenant, person_id: @person_id,
      framework_id: @framework.framework_id, cycle_id: @cycle_id,
      capability_stable_id: @capability2.stable_id, level_ordinal: 2,
      **frequencies)
  end

  def build_completion(context, level: @level)
    Assessments::MatrixDataBuilder.new(
      framework: @framework, role: @role, level: level,
      person_id: @person_id, cycle_id: @cycle_id, categories: @categories,
      context: context
    ).build
  end

  def build_self_data
    Assessments::MatrixDataBuilder.new(
      framework: @framework, role: @role, level: @level,
      person_id: @person_id, cycle_id: @cycle_id, categories: @categories,
      context: :self
    ).build
  end

  def build_snapshot_enrollment(role_id:, level_id:, level_ordinal:)
    AssessmentCycleEnrollment.create!(
      tenant: @tenant, cycle_id: @cycle_id, person_id: @person_id,
      status: "enrolled", enrolled_at: Time.current,
      role_id: role_id, level_id: level_id, level_ordinal: level_ordinal
    )
  end

  def build_for(viewer_person_id:, viewer_sees_all_evidence:)
    Assessments::MatrixDataBuilder.new(
      framework: @framework, role: @role, level: @level,
      person_id: @assessee.id,
      cycle_id: @cycle_id, categories: @categories, context: :manager,
      viewer_person_id: viewer_person_id,
      viewer_sees_all_evidence: viewer_sees_all_evidence
    ).build
  end
end
