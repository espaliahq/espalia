# frozen_string_literal: true

require "test_helper"

class EvidenceItemTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
  end

  context "validations" do
    should "be valid with all required fields" do
      ActsAsTenant.with_tenant(@tenant) do
        item = build(:evidence_item, tenant: @tenant)
        assert item.valid?, item.errors.full_messages.to_sentence
      end
    end

    should "accept an item with no origin cell, but not one with half a cell" do
      ActsAsTenant.with_tenant(@tenant) do
        unplaced = build(:evidence_item, tenant: @tenant, capability_stable_id: nil, level_ordinal: nil)
        half = build(:evidence_item, tenant: @tenant, level_ordinal: nil)

        assert unplaced.valid?, unplaced.errors.full_messages.to_sentence
        assert_not half.valid?
        assert half.errors[:base].any?
      end
    end

    should "require source from SOURCES" do
      ActsAsTenant.with_tenant(@tenant) do
        item = build(:evidence_item, tenant: @tenant, source: "garbage")
        assert_not item.valid?
        assert item.errors[:source].any?
      end
    end

    should "accept a known feedback direction or nil for historical evidence" do
      ActsAsTenant.with_tenant(@tenant) do
        current = build(:evidence_item, tenant: @tenant, feedback_direction: "report_to_manager")
        historical = build(:evidence_item, tenant: @tenant, feedback_direction: nil)
        invalid = build(:evidence_item, tenant: @tenant, feedback_direction: "sideways")

        assert current.valid?, current.errors.full_messages.to_sentence
        assert historical.valid?, historical.errors.full_messages.to_sentence
        assert_not invalid.valid?
        assert invalid.errors[:feedback_direction].any?
      end
    end

    should "require evidence_type from EVIDENCE_TYPES" do
      ActsAsTenant.with_tenant(@tenant) do
        item = build(:evidence_item, tenant: @tenant, evidence_type: "garbage")
        assert_not item.valid?
        assert item.errors[:evidence_type].any?
      end
    end

    should "accept 'observation' as an evidence_type" do
      ActsAsTenant.with_tenant(@tenant) do
        item = build(:evidence_item, tenant: @tenant, evidence_type: "observation")
        assert item.valid?, item.errors.full_messages.to_sentence
      end
    end

    should "accept the feedback-family and impact evidence_types" do
      ActsAsTenant.with_tenant(@tenant) do
        %w[manager_feedback customer_feedback impact].each do |type|
          item = build(:evidence_item, tenant: @tenant, evidence_type: type)
          assert item.valid?, "#{type}: #{item.errors.full_messages.to_sentence}"
        end
      end
    end

    should "require custom_type_label when type is 'other'" do
      ActsAsTenant.with_tenant(@tenant) do
        item = build(:evidence_item, tenant: @tenant, evidence_type: "other", custom_type_label: nil)
        assert_not item.valid?
        assert item.errors[:custom_type_label].any?
      end
    end

    should "reject custom_type_label when type is not 'other'" do
      ActsAsTenant.with_tenant(@tenant) do
        item = build(:evidence_item, tenant: @tenant, evidence_type: "code_review", custom_type_label: "Custom")
        assert_not item.valid?
        assert item.errors[:custom_type_label].any?
      end
    end

    should "require positive level_ordinal" do
      ActsAsTenant.with_tenant(@tenant) do
        item = build(:evidence_item, tenant: @tenant, level_ordinal: 0)
        assert_not item.valid?
      end
    end

    should "require content" do
      ActsAsTenant.with_tenant(@tenant) do
        item = build(:evidence_item, tenant: @tenant, content: "  ")
        assert_not item.valid?
        assert item.errors[:content].any?
      end
    end
  end
  context ".feedback_direction_for" do
    should "classify self, manager, upward, and lateral feedback at recording time" do
      ActsAsTenant.with_tenant(@tenant) do
        manager = create(:person, tenant: @tenant, name: "Manager")
        report = create(:person, tenant: @tenant, manager: manager, name: "Report")
        peer = create(:person, tenant: @tenant, name: "Peer")

        assert_equal "self",
          EvidenceItem.feedback_direction_for(source: "self", author: report, recipient: report)
        assert_equal "manager_to_report",
          EvidenceItem.feedback_direction_for(source: "manager", author: manager, recipient: report)
        assert_equal "report_to_manager",
          EvidenceItem.feedback_direction_for(source: "peer", author: report, recipient: manager)
        assert_equal "peer_to_peer",
          EvidenceItem.feedback_direction_for(source: "peer", author: peer, recipient: report)
      end
    end

    should "fall back to lateral feedback when historical people cannot be resolved" do
      assert_equal "peer_to_peer",
        EvidenceItem.feedback_direction_for(source: "peer", author: nil, recipient: nil)
    end
  end


  context "scopes" do
    should "filter active vs withdrawn" do
      ActsAsTenant.with_tenant(@tenant) do
        active = create(:evidence_item, tenant: @tenant)
        withdrawn = create(:evidence_item, tenant: @tenant, link_status: "withdrawn")

        assert_includes EvidenceItem.active, active
        assert_not_includes EvidenceItem.active, withdrawn
        assert_includes EvidenceItem.withdrawn, withdrawn
      end
    end

    should "scope by person and capability" do
      ActsAsTenant.with_tenant(@tenant) do
        person_id = SecureRandom.uuid_v7
        cap_id = SecureRandom.uuid_v7
        match = create(:evidence_item, tenant: @tenant, person_id: person_id, capability_stable_id: cap_id, level_ordinal: 4)
        create(:evidence_item, tenant: @tenant) # noise

        result = EvidenceItem.for_person(person_id).for_capability(cap_id).at_level(4)
        assert_equal [ match.id ], result.pluck(:id)
      end
    end
  end

  context "external_reference" do
    should "round-trip via store_model" do
      ActsAsTenant.with_tenant(@tenant) do
        item = create(:evidence_item, tenant: @tenant,
          external_reference: { system: "github", url: "https://github.com/x/y/pull/1" })
        item.reload
        assert_equal "github", item.external_reference.system
        assert_equal "https://github.com/x/y/pull/1", item.external_reference.url
      end
    end

    should "default to an empty ExternalReference" do
      ActsAsTenant.with_tenant(@tenant) do
        item = create(:evidence_item, tenant: @tenant)
        item.reload
        assert_kind_of ExternalReference, item.external_reference
        assert_not item.external_reference.present?
      end
    end
  end
end
