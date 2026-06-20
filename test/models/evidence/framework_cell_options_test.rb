# frozen_string_literal: true

require "test_helper"

class Evidence::FrameworkCellOptionsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    framework_id = SecureRandom.uuid_v7
    create(:framework_state, framework_id: framework_id, name: "Eng")
    rf = create(:framework_role_family, framework_id: framework_id, name: "Eng")
    @role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
    create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")
    @cat = create(:framework_capability_category, framework_id: framework_id, name: "Thinking", ordinal: 1)
    @framework_id = framework_id
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def bind(capability)
    create(:framework_capability_role_binding, capability_id: capability.capability_id, role_id: @role.role_id, weight: 1.0)
  end

  def options
    Evidence::FrameworkCellOptions.new(framework_id: @framework_id, role_id: @role.role_id)
  end

  should "offer bound, active capabilities and only cells that have an expectation" do
    bound = create(:framework_capability, category_id: @cat.category_id, name: "Critical Thinking")
    bind(bound)
    exp = create(:framework_behavioural_expectation, capability_id: bound.capability_id, level_ordinal: 2, description: "Weighs options")
    create(:framework_role_illustration, expectation_id: exp.expectation_id, role_id: @role.role_id, ordinal: 1, description: "x")

    names = options.link_options.flat_map { |g| g[:capabilities].map { |c| c[:name] } }
    assert_includes names, "Critical Thinking"
    assert_equal({ "#{bound.stable_id}|2" => { capability_name: "Critical Thinking", expectation: "Weighs options" } }, options.expectation_map)
    assert_equal [ { ordinal: 2, label: "L2 — Mid" } ], options.level_options
  end

  should "exclude inactive and unbound capabilities" do
    inactive = create(:framework_capability, category_id: @cat.category_id, name: "Archived", status: "archived")
    bind(inactive)
    unbound = create(:framework_capability, category_id: @cat.category_id, name: "Unbound")
    create(:framework_behavioural_expectation, capability_id: unbound.capability_id, level_ordinal: 2, description: "y")

    names = options.link_options.flat_map { |g| g[:capabilities].map { |c| c[:name] } }
    assert_not_includes names, "Archived"
    assert_not_includes names, "Unbound"
  end
end
