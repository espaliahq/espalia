# frozen_string_literal: true

require "test_helper"

# `for_lens` preloads only what the lens role reads (#487): its bound
# capabilities, their expectations and its own illustrations. The output must
# match a builder handed the whole framework tree.
class Assessments::MatrixDataBuilderRoleTreeTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @fx = build_role_lens_framework(tenant: @tenant)
    @person = create(:person, tenant: @tenant)
    @assignment, @cycle_id = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant)

    [ @fx.shared, @fx.e_only, @fx.pm_only ].each do |capability|
      FrameworkState::BehaviouralExpectation.where(capability_id: capability.capability_id).find_each do |expectation|
        [ @fx.engineer, @fx.pm ].each_with_index do |role, i|
          create(:framework_role_illustration, tenant: @tenant, expectation_id: expectation.expectation_id,
                 role_id: role.role_id, ordinal: i + 1, description: "#{role.code} example")
        end
      end
    end
  end

  def build(lens) = Assessments::MatrixDataBuilder.for_lens(lens: lens, context: :self)

  # The builder as it was before #487 — handed every capability, expectation
  # and illustration in the framework.
  def build_from_full_tree(lens)
    status = @assignment.current_open_cycle_participation&.status
    Assessments::MatrixDataBuilder.new(
      framework: @fx.framework, lens: lens, person_id: @person.id, cycle_id: @cycle_id,
      categories: FrameworkState::CapabilityCategory.where(framework_id: @fx.framework_id, status: "active")
        .includes(capabilities: [ :bindings, { expectations: :illustrations } ]).order(:ordinal),
      participant_status: status,
      disclosure: Assessments::Disclosure.for(lens: lens, participant_status: status),
      context: :self
    ).build
  end

  def digest(data)
    data[:categories].map do |category|
      [ category[:category].category_id, category[:capabilities].map do |cap|
        [ cap[:capability].stable_id, cap[:in_home_role],
          cap[:cells].transform_values { |cell| [ cell[:expectation].expectation_id, cell[:illustrations].map(&:illustration_id) ] } ]
      end ]
    end
  end

  def instantiated
    counts = Hash.new(0)
    callback = ->(*, payload) { counts[payload[:class_name]] += payload[:record_count] }
    ActiveSupport::Notifications.subscribed(callback, "instantiation.active_record") { yield }
    counts
  end

  context "the home read" do
    setup { @lens = Assessments::Lens.resolve(assignment: @assignment, as_role: nil, as_level: nil) }

    should "match a build from the whole framework tree" do
      assert_equal digest(build_from_full_tree(@lens)), digest(build(@lens))
    end

    should "show only the engineer's capabilities and examples" do
      data = build(@lens)
      names = data[:categories].flat_map { |c| c[:capabilities].map { |cap| cap[:capability].name } }
      assert_equal [ "Critical Thinking", "Systems Design" ], names.sort
      examples = data[:categories].flat_map { |c| c[:capabilities].flat_map { |cap| cap[:cells].values.flat_map { |cell| cell[:illustrations] } } }
      assert_equal [ "E example" ], examples.map(&:description).uniq
    end

    should "not load capabilities or examples another role reads" do
      fresh = -> { Assessments::Lens.resolve(assignment: @assignment, as_role: nil, as_level: nil) }
      full = instantiated { build_from_full_tree(fresh.call) }
      scoped = instantiated { build(fresh.call) }
      assert_equal 1, full["FrameworkState::Capability"] - scoped["FrameworkState::Capability"],
        "Roadmapping, which only the product manager reads, is never loaded"
      assert_equal 6, scoped["FrameworkState::RoleIllustration"], "the engineer's examples only"
    end
  end

  context "a lens on another role" do
    setup { @lens = Assessments::Lens.resolve(assignment: @assignment, as_role: @fx.pm.role_id, as_level: "2") }

    should "match a build from the whole framework tree" do
      assert_equal digest(build_from_full_tree(@lens)), digest(build(@lens))
    end

    should "load the lens role's examples, not the home role's" do
      counts = instantiated { build(@lens) }
      assert_equal 6, counts["FrameworkState::RoleIllustration"]
    end
  end
end
