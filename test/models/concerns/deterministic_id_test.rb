# frozen_string_literal: true

require "test_helper"

# Pins the DeterministicId mechanism in isolation. The projection round-trip
# tests prove stability across reset! + replay against real event streams;
# this pins the derivation itself so an accidental change to the namespace,
# attribute set, ordering, or format is caught directly.
class DeterministicIdTest < ActiveSupport::TestCase
  # Fixed, valid UUIDs — the `person_id` / `framework_id` columns are `uuid`,
  # so a non-UUID string would cast to nil and the natural key would look blank.
  PERSON     = "11111111-1111-1111-1111-111111111111"
  FRAMEWORK  = "22222222-2222-2222-2222-222222222222"
  FRAMEWORK2 = "33333333-3333-3333-3333-333333333333"

  # PersonFrameworkAssignment is a real consumer of the concern, keyed on
  # (person_id, framework_id) — use it rather than a synthetic AR class so
  # the test exercises the actual declaration.
  def build(person_id:, framework_id:)
    PersonFrameworkAssignment.new(
      tenant_id: SecureRandom.uuid_v7,
      person_id: person_id,
      framework_id: framework_id,
      role_id: SecureRandom.uuid_v7,
      level_id: SecureRandom.uuid_v7
    ).tap(&:valid?)
  end

  context "DeterministicId" do
    should "derive the same id for the same natural key" do
      a = build(person_id: PERSON, framework_id: FRAMEWORK)
      b = build(person_id: PERSON, framework_id: FRAMEWORK)
      assert_equal a.id, b.id
    end

    should "derive different ids for different natural keys" do
      a = build(person_id: PERSON, framework_id: FRAMEWORK)
      b = build(person_id: PERSON, framework_id: FRAMEWORK2)
      assert_not_equal a.id, b.id
    end

    should "not collide across models that share a natural key" do
      assignment = build(person_id: PERSON, framework_id: FRAMEWORK)
      delegation = ManagerAssessmentDelegation.new(
        tenant_id: SecureRandom.uuid_v7, person_id: PERSON, framework_id: FRAMEWORK,
        delegate_person_id: SecureRandom.uuid_v7, granted_by_id: SecureRandom.uuid_v7, status: "active"
      ).tap(&:valid?)
      # Even the shared (person, framework) prefix is namespaced by class name,
      # so the two models can never derive the same id.
      assert_not_equal assignment.id, delegation.id
    end

    should "respect an explicitly supplied id" do
      explicit = "00000000-0000-0000-0000-000000000001"
      record = PersonFrameworkAssignment.new(
        id: explicit, tenant_id: SecureRandom.uuid_v7,
        person_id: PERSON, framework_id: FRAMEWORK,
        role_id: SecureRandom.uuid_v7, level_id: SecureRandom.uuid_v7
      )
      record.valid?
      assert_equal explicit, record.id
    end

    should "produce the frozen UUIDv5 for known inputs (derivation must not drift)" do
      # If this fails, the namespace/attribute-order/format changed — which
      # would reissue every historical row's id on the next rebuild. Treat the
      # derivation as immutable; do not update this value to make it pass.
      assert_equal "b5b11bb9-f080-5e44-97f6-fcab092e3f67",
        build(person_id: PERSON, framework_id: FRAMEWORK).id
    end

    should "leave the id blank when a natural-key value is missing" do
      record = PersonFrameworkAssignment.new(
        tenant_id: SecureRandom.uuid_v7, person_id: PERSON, framework_id: nil,
        role_id: SecureRandom.uuid_v7, level_id: SecureRandom.uuid_v7
      )
      record.valid?
      assert_nil record.id
    end
  end
end
