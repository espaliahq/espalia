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

    should "require source from SOURCES" do
      ActsAsTenant.with_tenant(@tenant) do
        item = build(:evidence_item, tenant: @tenant, source: "garbage")
        assert_not item.valid?
        assert item.errors[:source].any?
      end
    end

    should "require evidence_type from EVIDENCE_TYPES" do
      ActsAsTenant.with_tenant(@tenant) do
        item = build(:evidence_item, tenant: @tenant, evidence_type: "garbage")
        assert_not item.valid?
        assert item.errors[:evidence_type].any?
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
