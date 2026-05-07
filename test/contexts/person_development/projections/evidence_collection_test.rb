# frozen_string_literal: true

require "test_helper"

class PersonDevelopment::Projections::EvidenceCollectionTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @projection = PersonDevelopment::Projections::EvidenceCollection.new
    @person_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7

    ActsAsTenant.with_tenant(@tenant) do
      @author = create(:person, tenant: @tenant, name: "Author")
    end
  end

  context "EvidenceRecorded" do
    should "create an EvidenceItem row" do
      evidence_id = SecureRandom.uuid_v7
      cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: evidence_id,
        capability_stable_id: cap_sid,
        level_ordinal: 3,
        source: "manager",
        evidence_type: "code_review",
        custom_type_label: nil,
        title: "Reviewed PR",
        content: "Strong testing approach",
        external_reference: { system: "github", url: "https://github.com/o/r/pull/1" },
        author_id: @author.id)

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(evidence_id)
        assert_equal @person_id, item.person_id
        assert_equal @framework_id, item.framework_id
        assert_equal cap_sid, item.capability_stable_id
        assert_equal 3, item.level_ordinal
        assert_equal "manager", item.source
        assert_equal "code_review", item.evidence_type
        assert_equal "Reviewed PR", item.title
        assert_equal "Strong testing approach", item.content
        assert_equal "github", item.external_reference.system
        assert_equal @author.id, item.author_id
        assert_equal "active", item.link_status
        assert_not_nil item.recorded_at
      end
    end

    should "default external_reference to empty when nil" do
      evidence_id = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: evidence_id,
        capability_stable_id: SecureRandom.uuid_v7,
        level_ordinal: 1, source: "self", evidence_type: "project_outcome",
        custom_type_label: nil, title: nil, content: "x",
        external_reference: nil, author_id: @author.id)

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(evidence_id)
        assert_kind_of ExternalReference, item.external_reference
        assert_not item.external_reference.present?
      end
    end
  end

  context "EvidenceRelinked" do
    should "update capability and level on the existing row" do
      evidence_id = SecureRandom.uuid_v7
      cap_sid = SecureRandom.uuid_v7
      new_cap_sid = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: evidence_id, capability_stable_id: cap_sid, level_ordinal: 2,
        source: "self", evidence_type: "project_outcome", custom_type_label: nil,
        title: nil, content: "x", external_reference: nil, author_id: @author.id)

      emit(PersonDevelopment::Events::EvidenceRelinked,
        evidence_id: evidence_id,
        previous_capability_stable_id: cap_sid, previous_level_ordinal: 2,
        new_capability_stable_id: new_cap_sid, new_level_ordinal: 4,
        relinked_by_id: @author.id, rationale: "Better fit")

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(evidence_id)
        assert_equal new_cap_sid, item.capability_stable_id
        assert_equal 4, item.level_ordinal
        assert_equal "active", item.link_status
      end
    end

    should "be a no-op when the row is missing" do
      assert_nothing_raised do
        emit(PersonDevelopment::Events::EvidenceRelinked,
          evidence_id: SecureRandom.uuid_v7,
          previous_capability_stable_id: SecureRandom.uuid_v7, previous_level_ordinal: 1,
          new_capability_stable_id: SecureRandom.uuid_v7, new_level_ordinal: 2,
          relinked_by_id: @author.id, rationale: nil)
      end
    end
  end

  context "EvidenceWithdrawn" do
    should "flip link_status and stamp withdrawal fields" do
      evidence_id = SecureRandom.uuid_v7

      emit(PersonDevelopment::Events::EvidenceRecorded,
        evidence_id: evidence_id, capability_stable_id: SecureRandom.uuid_v7,
        level_ordinal: 1, source: "self", evidence_type: "project_outcome",
        custom_type_label: nil, title: nil, content: "x",
        external_reference: nil, author_id: @author.id)

      emit(PersonDevelopment::Events::EvidenceWithdrawn,
        evidence_id: evidence_id, withdrawn_by_id: @author.id, reason: "Wrong context")

      ActsAsTenant.with_tenant(@tenant) do
        item = EvidenceItem.find(evidence_id)
        assert_equal "withdrawn", item.link_status
        assert_equal @author.id, item.withdrawn_by_id
        assert_equal "Wrong context", item.withdrawal_reason
        assert_not_nil item.withdrawn_at
      end
    end
  end

  private

  def emit(event_class, **data)
    event = event_class.new(
      data: data,
      metadata: {
        tenant_id: @tenant.id,
        person_id: @person_id,
        framework_id: @framework_id
      }
    )
    @projection.call(event)
  end
end
