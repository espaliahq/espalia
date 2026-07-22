# frozen_string_literal: true

require "test_helper"

class PersonDevelopmentCommentTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
  end

  context "validations" do
    should "be valid with all required fields" do
      ActsAsTenant.with_tenant(@tenant) do
        c = build(:person_development_comment, tenant: @tenant)
        assert c.valid?, c.errors.full_messages.to_sentence
      end
    end

    should "require body" do
      ActsAsTenant.with_tenant(@tenant) do
        c = build(:person_development_comment, tenant: @tenant, body: "")
        assert_not c.valid?
        assert c.errors[:body].any?
      end
    end

    should "require commentable_type from COMMENTABLE_TYPES" do
      ActsAsTenant.with_tenant(@tenant) do
        c = build(:person_development_comment, tenant: @tenant, commentable_type: "garbage")
        assert_not c.valid?
        assert c.errors[:commentable_type].any?
      end
    end

    should "require capability_stable_id for assessment_cell" do
      ActsAsTenant.with_tenant(@tenant) do
        c = build(:person_development_comment, tenant: @tenant, capability_stable_id: nil)
        assert_not c.valid?
        assert c.errors[:capability_stable_id].any?
      end
    end

    should "require positive level_ordinal for assessment_cell" do
      ActsAsTenant.with_tenant(@tenant) do
        c = build(:person_development_comment, tenant: @tenant, level_ordinal: 0)
        assert_not c.valid?
      end
    end

    should "require evidence_id for evidence_link" do
      ActsAsTenant.with_tenant(@tenant) do
        c = build(:person_development_comment, tenant: @tenant,
          commentable_type: PersonDevelopmentComment::EVIDENCE_LINK, evidence_id: nil)
        assert_not c.valid?
        assert c.errors[:evidence_id].any?

        c.evidence_id = SecureRandom.uuid_v7
        assert c.valid?, c.errors.full_messages.to_sentence
      end
    end

    should "require cell coordinates for evidence_link" do
      ActsAsTenant.with_tenant(@tenant) do
        c = build(:person_development_comment, tenant: @tenant,
          commentable_type: PersonDevelopmentComment::EVIDENCE_LINK,
          evidence_id: SecureRandom.uuid_v7, capability_stable_id: nil)
        assert_not c.valid?
        assert c.errors[:capability_stable_id].any?
      end
    end

    should "require status in STATUSES" do
      ActsAsTenant.with_tenant(@tenant) do
        c = build(:person_development_comment, tenant: @tenant, status: "garbage")
        assert_not c.valid?
        assert c.errors[:status].any?
      end
    end
  end

  context "scopes" do
    should "filter active vs deleted" do
      ActsAsTenant.with_tenant(@tenant) do
        active = create(:person_development_comment, tenant: @tenant)
        deleted = create(:person_development_comment, tenant: @tenant, status: "deleted")

        assert_includes PersonDevelopmentComment.active, active
        assert_not_includes PersonDevelopmentComment.active, deleted
        assert_includes PersonDevelopmentComment.deleted, deleted
      end
    end

    should "scope by cell coordinate" do
      ActsAsTenant.with_tenant(@tenant) do
        person_id = SecureRandom.uuid_v7
        cap_id = SecureRandom.uuid_v7
        match = create(:person_development_comment, tenant: @tenant,
          person_id: person_id, capability_stable_id: cap_id, level_ordinal: 4)
        create(:person_development_comment, tenant: @tenant) # noise

        result = PersonDevelopmentComment.for_person(person_id).on_cell(cap_id, 4)
        assert_equal [ match.id ], result.pluck(:id)
      end
    end

    should "scope by evidence linkage" do
      ActsAsTenant.with_tenant(@tenant) do
        evidence_id = SecureRandom.uuid_v7
        cap_id = SecureRandom.uuid_v7
        match = create(:person_development_comment, tenant: @tenant,
          commentable_type: PersonDevelopmentComment::EVIDENCE_LINK,
          evidence_id: evidence_id, capability_stable_id: cap_id, level_ordinal: 4)
        # Same cell, but a plain cell comment — must not leak into the linkage thread.
        create(:person_development_comment, tenant: @tenant,
          capability_stable_id: cap_id, level_ordinal: 4)

        result = PersonDevelopmentComment.on_evidence_link(evidence_id, cap_id, 4)
        assert_equal [ match.id ], result.pluck(:id)
      end
    end

    should "distinguish top-level from replies" do
      ActsAsTenant.with_tenant(@tenant) do
        top = create(:person_development_comment, tenant: @tenant)
        reply = create(:person_development_comment, tenant: @tenant, parent_id: top.id,
          capability_stable_id: top.capability_stable_id, level_ordinal: top.level_ordinal)

        assert_includes PersonDevelopmentComment.top_level, top
        assert_not_includes PersonDevelopmentComment.top_level, reply
      end
    end
  end

  context "#deleted?" do
    should "return true when status is deleted" do
      ActsAsTenant.with_tenant(@tenant) do
        c = build(:person_development_comment, tenant: @tenant, status: "deleted")
        assert c.deleted?
      end
    end
  end
end
