# frozen_string_literal: true

require "test_helper"

# Hygiene checks on the Operations registry. Catches the easy mistakes
# we'd otherwise discover at MCP runtime: an Operation with no
# description, no category, an unstable name, or one whose tool-name
# collides with another's.
class Operations::RegistryTest < ActiveSupport::TestCase
  setup { @ops = Operations::Registry.all }

  should "discover at least one concrete operation" do
    refute_empty @ops, "Operations::Registry is empty — eager-load not firing?"
  end

  should "exclude anonymous subclasses" do
    @ops.each do |op|
      refute_nil op.name, "anonymous Operations subclass slipped into the registry: #{op.inspect}"
    end
  end

  should "have a non-blank description on every operation" do
    bad = @ops.reject { |op| op.description.present? }
    assert_empty bad, "Operations missing a description: #{bad.map(&:name)}"
  end

  should "have a known category on every operation" do
    bad = @ops.reject { |op| Operations::Base::CATEGORIES.include?(op.category) }
    assert_empty bad, "Operations with an invalid category: #{bad.map(&:name)}"
  end

  should "have a known approval on every operation" do
    bad = @ops.reject { |op| Operations::Base::APPROVALS.include?(op.approval) }
    assert_empty bad, "Operations with an invalid approval: #{bad.map(&:name)}"
  end

  should "produce unique tool names" do
    names = @ops.map { |op| Operations::Registry.tool_name_for(op) }
    duplicates = names.group_by(&:itself).select { |_, v| v.size > 1 }.keys
    assert_empty duplicates, "duplicate tool names: #{duplicates.inspect}"
  end
end
