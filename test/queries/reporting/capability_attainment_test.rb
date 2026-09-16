# frozen_string_literal: true

require "test_helper"

class Reporting::CapabilityAttainmentTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @framework_id = SecureRandom.uuid_v7

    @family_eng = create(:framework_role_family, framework_id: @framework_id, name: "Engineering")
    @family_design = create(:framework_role_family, framework_id: @framework_id, name: "Design")

    @engineer = create(:framework_role, name: "Software Engineer", code: "E",
      role_family_id: @family_eng.role_family_id)
    @manager = create(:framework_role, name: "Engineering Manager", code: "EM", track: "management",
      role_family_id: @family_eng.role_family_id)
    @designer = create(:framework_role, name: "Product Designer", code: "PD",
      role_family_id: @family_design.role_family_id)

    [ @engineer, @manager, @designer ].each do |role|
      (1..3).each { |ordinal| create(:framework_level, role_id: role.role_id, ordinal: ordinal, code: "#{role.code}#{ordinal}") }
    end

    @thinking = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking")
    @craft = create(:framework_capability_category, framework_id: @framework_id, name: "Craft")

    # cap1 bound to engineer + manager; cap2 engineer-only; cap3 designer-only.
    @cap1 = create(:framework_capability, category_id: @thinking.category_id, name: "Strategic Thinking")
    @cap2 = create(:framework_capability, category_id: @thinking.category_id, name: "Problem Solving")
    @cap3 = create(:framework_capability, category_id: @craft.category_id, name: "Visual Design")
    bind(@cap1, @engineer)
    bind(@cap1, @manager)
    bind(@cap2, @engineer)
    bind(@cap3, @designer)

    # Every rated cell sits on a behavioural expectation, as in real data —
    # the engine normalises each level's band over the cells that have one.
    [ @cap1, @cap2, @cap3 ].each do |cap|
      (1..3).each do |ordinal|
        create(:framework_behavioural_expectation, tenant: @tenant,
               capability_id: cap.capability_id, level_ordinal: ordinal)
      end
    end

    @cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id, status: "open")
  end

  teardown { ActsAsTenant.current_tenant = nil }

  context "bucketing per person × capability" do
    setup do
      # Ada: consistent at her level on cap1 → :at. cap2 unrated → :below, unassessed.
      @ada = enroll(create(:person, tenant: @tenant, name: "Ada"), @engineer)
      rate(@ada, @cap1, ordinal: 2, self_rated_frequency: "consistent")

      # Bo: consistent at level 2 AND 3 on cap1 → :above.
      @bo = enroll(create(:person, tenant: @tenant, name: "Bo"), @engineer)
      rate(@bo, @cap1, ordinal: 2, self_rated_frequency: "consistent")
      rate(@bo, @cap1, ordinal: 3, self_rated_frequency: "consistent")

      # Cy: occasional at level 2 on cap1 → :below, but assessed.
      @cy = enroll(create(:person, tenant: @tenant, name: "Cy"), @engineer)
      rate(@cy, @cap1, ordinal: 2, self_rated_frequency: "occasional")
    end

    should "bucket at / above / below against the assessed level" do
      cell = engineer_group.cells[@cap1.stable_id]
      assert_equal 1, cell.at
      assert_equal 1, cell.above
      assert_equal 1, cell.below
      assert_equal 3, cell.n_in_group
      assert_equal 67, cell.at_or_above_pct
    end

    should "count unrated capabilities as below with zero assessed" do
      cell = engineer_group.cells[@cap2.stable_id]
      assert_equal 3, cell.below
      assert_equal 0, cell.n_assessed
      assert_equal 0, cell.at_or_above_pct
    end

    should "count own-level explicit ratings as assessed" do
      cell = engineer_group.cells[@cap1.stable_id]
      assert_equal 3, cell.n_assessed
      assert_equal 100, cell.assessed_pct
    end

    should "not count a rating at another level as assessed" do
      dee = enroll(create(:person, tenant: @tenant, name: "Dee"), @engineer)
      rate(dee, @cap2, ordinal: 3, self_rated_frequency: "occasional")

      cell = engineer_group.cells[@cap2.stable_id]
      assert_equal 0, cell.n_assessed
      assert_equal 4, cell.below
    end

    should "expose the row skeleton sorted by category then capability name" do
      enroll(create(:person, tenant: @tenant, name: "Des"), @designer)

      rows = result.capabilities
      assert_equal [ @cap3, @cap2, @cap1 ].map(&:stable_id), rows.map(&:stable_id)
      assert_equal %w[Craft Thinking], result.categories.map(&:name)
    end

    should "only include capabilities bound to roles with participants" do
      assert_equal [ @cap2, @cap1 ].map(&:stable_id), result.capabilities.map(&:stable_id)
      assert_equal %w[Thinking], result.categories.map(&:name)
    end
  end

  context "perspectives" do
    setup do
      # Self says consistent, manager says occasional at the assessed level.
      @person = enroll(create(:person, tenant: @tenant, name: "Split"), @engineer)
      rate(@person, @cap1, ordinal: 2,
        self_rated_frequency: "consistent", manager_rated_frequency: "occasional")
    end

    should "follow the aligned → manager → self fallback chain by default" do
      cell = engineer_group.cells[@cap1.stable_id]
      assert_equal 1, cell.below
      assert_equal 0, cell.at
    end

    should "score self-only when requested" do
      cell = engineer_group(perspective: :self_only).cells[@cap1.stable_id]
      assert_equal 1, cell.at
    end

    should "treat a cell unrated under the active perspective as unassessed" do
      cell = engineer_group(perspective: :aligned_only).cells[@cap1.stable_id]
      assert_equal 0, cell.n_assessed
      assert_equal 1, cell.below
    end

    should "reject an unknown perspective" do
      assert_raises(ArgumentError) do
        Reporting::CapabilityAttainment.new(cycle: @cycle, perspective: :bogus)
      end
    end
  end

  context "family roll-up denominators" do
    setup do
      2.times { |i| enroll(create(:person, tenant: @tenant, name: "Eng #{i}"), @engineer) }
      enroll(create(:person, tenant: @tenant, name: "Mgr"), @manager)
    end

    should "count only people whose role binds the capability" do
      family = family_group(@family_eng.role_family_id)
      assert_equal 3, family.cells[@cap1.stable_id].n_in_group
      assert_equal 2, family.cells[@cap2.stable_id].n_in_group
    end

    should "keep families separate" do
      enroll(create(:person, tenant: @tenant, name: "Des"), @designer)

      design = family_group(@family_design.role_family_id)
      assert_equal 1, design.n_people
      assert_nil design.cells[@cap1.stable_id]
    end
  end

  context "category gate roll-up" do
    setup do
      # Failing: both Thinking capabilities at "none" → pool -2 < -1 (default threshold).
      @failing = enroll(create(:person, tenant: @tenant, name: "Failing"), @engineer)
      rate(@failing, @cap1, ordinal: 2, self_rated_frequency: "none")
      rate(@failing, @cap2, ordinal: 2, self_rated_frequency: "none")

      # Passing: consistent on both.
      @passing = enroll(create(:person, tenant: @tenant, name: "Passing"), @engineer)
      rate(@passing, @cap1, ordinal: 2, self_rated_frequency: "consistent")
      rate(@passing, @cap2, ordinal: 2, self_rated_frequency: "consistent")
    end

    should "report the share of people passing the category gate" do
      cell = engineer_group.category_cells[@thinking.category_id]
      assert_equal 1, cell.pass_count
      assert_equal 2, cell.n_in_group
      assert_equal 50, cell.pass_pct
    end

    should "not include categories the role has no bindings in" do
      assert_nil engineer_group.category_cells[@craft.category_id]
    end
  end

  context "small-cohort suppression" do
    should "suppress buckets but keep coverage counts under the floor" do
      2.times { |i| enroll(create(:person, tenant: @tenant, name: "Eng #{i}"), @engineer) }

      cell = engineer_group(suppress: true).cells[@cap1.stable_id]
      assert cell.suppressed
      assert_nil cell.at
      assert_nil cell.at_or_above_pct
      assert_equal 2, cell.n_in_group
      assert_equal 0, cell.n_assessed
    end

    should "not suppress at or above the floor" do
      4.times { |i| enroll(create(:person, tenant: @tenant, name: "Eng #{i}"), @engineer) }

      cell = engineer_group(suppress: true).cells[@cap1.stable_id]
      assert_not cell.suppressed
      assert_equal 4, cell.n_in_group
    end

    should "not suppress anything for full-access viewers" do
      enroll(create(:person, tenant: @tenant, name: "Solo"), @engineer)

      cell = engineer_group.cells[@cap1.stable_id]
      assert_not cell.suppressed
      assert_nil result.suppression_floor
    end

    should "suppress the family cell when visible role cells would reveal the remainder" do
      4.times { |i| enroll(create(:person, tenant: @tenant, name: "Eng #{i}"), @engineer) }
      2.times { |i| enroll(create(:person, tenant: @tenant, name: "Mgr #{i}"), @manager) }

      res = result(suppress: true)
      family = res.families.find { |g| g.key == @family_eng.role_family_id }
      # cap1: engineer cell (n=4) visible, manager cell (n=2) suppressed —
      # family n=6 minus visible 4 leaves a reconstructable cohort of 2.
      assert family.cells[@cap1.stable_id].suppressed
      # cap2 is engineer-only: family cell (n=4) equals the visible role cell — safe.
      assert_not family.cells[@cap2.stable_id].suppressed
    end

    should "not apply the differencing guard when all role cells are visible" do
      4.times { |i| enroll(create(:person, tenant: @tenant, name: "Eng #{i}"), @engineer) }
      4.times { |i| enroll(create(:person, tenant: @tenant, name: "Mgr #{i}"), @manager) }

      family = result(suppress: true).families.find { |g| g.key == @family_eng.role_family_id }
      assert_not family.cells[@cap1.stable_id].suppressed
      assert_equal 8, family.cells[@cap1.stable_id].n_in_group
    end
  end

  context "scoping and edge cases" do
    should "restrict to scope_person_ids" do
      ada = create(:person, tenant: @tenant, name: "Ada")
      enroll(ada, @engineer)
      enroll(create(:person, tenant: @tenant, name: "Bo"), @engineer)

      scoped = Reporting::CapabilityAttainment.new(cycle: @cycle, scope_person_ids: [ ada.id ]).call
      assert_equal 1, scoped.total_people
    end

    should "exclude enrollments without a snapshot role or level" do
      person = create(:person, tenant: @tenant, name: "No role")
      create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: @cycle, person_id: person.id,
        role_id: nil, level_ordinal: nil, status: "enrolled")

      assert_equal 0, result.total_people
      assert_not result.any?
    end

    should "return an empty result for a cycle with no participants" do
      res = result
      assert_not res.any?
      assert_empty res.roles
      assert_empty res.families
    end
  end

  private

  def result(perspective: :effective, suppress: false)
    Reporting::CapabilityAttainment.new(
      cycle: @cycle, perspective: perspective, suppress_small_groups: suppress
    ).call
  end

  def engineer_group(perspective: :effective, suppress: false)
    result(perspective: perspective, suppress: suppress)
      .roles.find { |group| group.key == @engineer.role_id }
  end

  def family_group(family_key)
    result.families.find { |group| group.key == family_key }
  end

  def bind(capability, role)
    create(:framework_capability_role_binding,
      capability_id: capability.capability_id, role_id: role.role_id)
  end

  def enroll(person, role, ordinal: 2)
    create(:assessment_cycle_enrollment,
      tenant: @tenant, cycle: @cycle, person_id: person.id,
      role_id: role.role_id, level_ordinal: ordinal, status: "enrolled")
    person
  end

  def rate(person, capability, ordinal:, **frequencies)
    create(:assessment_level_rating,
      tenant: @tenant, cycle_id: @cycle.cycle_id, person_id: person.id,
      framework_id: @framework_id, capability_stable_id: capability.stable_id,
      level_ordinal: ordinal, **frequencies)
  end
end
