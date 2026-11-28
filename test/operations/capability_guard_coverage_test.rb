# frozen_string_literal: true

require "test_helper"

# #615: a tool that writes against a capability must check it is active in the
# published framework. A new tool taking `capability_stable_id` fails here until
# it includes the guard or is exempted with a reason.
class Operations::CapabilityGuardCoverageTest < ActiveSupport::TestCase
  EXEMPT = {
    "Operations::Assessments::SetEvidenceLinkValence" => "acts only on a link that already exists, so old links can be tidied",
    "Operations::Assessments::RemoveEvidenceLink" => "acts only on a link that already exists, so old links can be tidied"
  }.freeze

  def guarded?(operation)
    operation < Operations::CapabilityGuard || operation < Operations::Assessments::RatingCell
  end

  should "guard every write that takes a capability_stable_id" do
    writes = Operations::Registry.all.select do |operation|
      operation.category != :read && operation.parameters.key?(:capability_stable_id)
    end
    assert_operator writes.size, :>=, 11, "the registry should list the capability writes"

    unguarded = writes.reject { |operation| guarded?(operation) || EXEMPT.key?(operation.name) }.map(&:name)
    assert_empty unguarded, "include Operations::CapabilityGuard, or add an EXEMPT entry with a reason"
  end

  should "exempt only operations that still exist and still need it" do
    EXEMPT.each_key do |name|
      operation = name.constantize
      assert operation.parameters.key?(:capability_stable_id), "#{name} no longer takes capability_stable_id"
      assert_not guarded?(operation), "#{name} is guarded now; drop its exemption"
    end
  end
end
