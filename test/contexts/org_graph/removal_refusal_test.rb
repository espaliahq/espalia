# frozen_string_literal: true

require "test_helper"

class OrgGraph::RemovalRefusalTest < ActiveSupport::TestCase
  class BrokenRemoval < OrgGraph::StructureAggregate
    def remove_level(...) = raise(NoMethodError, "a bug, not a refusal")
  end

  class RefusingRemoval < OrgGraph::StructureAggregate
    def remove_level(...) = raise("Guild is still held")
  end

  setup { ActsAsTenant.current_tenant = create(:tenant) }
  teardown { ActsAsTenant.current_tenant = nil }

  should "report a bug inside remove_level rather than read it as a refusal" do
    assert_error_reported(NoMethodError) do
      assert_equal "a bug, not a refusal", BrokenRemoval.new.removal_refusal(SecureRandom.uuid_v7)
    end
  end

  should "return a refusal without reporting it" do
    assert_no_error_reported do
      assert_equal "Guild is still held", RefusingRemoval.new.removal_refusal(SecureRandom.uuid_v7)
    end
  end

  should "find a type that can go without removing it or leaving an event to publish" do
    structure = OrgGraph::StructureAggregate.new
    team, squad = Array.new(2) { SecureRandom.uuid_v7 }
    structure.define_taxonomy([ { level_id: team, name: "Team" }, { level_id: squad, name: "Squad" } ], effective_on: Date.yesterday)
    pending = structure.unpublished_events.to_a.size

    assert_nil structure.removal_refusal(squad)
    assert_equal [ team, squad ], structure.taxonomy.kinds.map(&:id)
    assert_equal pending, structure.unpublished_events.to_a.size
    assert_not structure.instance_variable_defined?(:@dry_run)
  end
end
