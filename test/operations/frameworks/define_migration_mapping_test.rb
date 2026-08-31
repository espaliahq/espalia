# frozen_string_literal: true

require "test_helper"

# Checks the DefineMigrationMapping Operation: it records a mapping for the
# open draft, derives requires_reassessment from the type, and re-defining
# with the same mapping_id edits in place (upsert) rather than duplicating —
# the path the owner/editor uses to override an as-we-go choice at publish.
class Operations::Frameworks::DefineMigrationMappingTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      handler.publish_version(@framework_id, "seed")  # v1
      handler.start_draft(@framework_id, 2, "seed")   # open a draft to map into
    end

    @from = SecureRandom.uuid_v7
    @to = SecureRandom.uuid_v7
    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def mappings
    FrameworkState::MigrationMapping.where(framework_id: @framework_id)
  end

  context "as a tenant admin" do
    should "record a mapping and derive requires_reassessment for evolved" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::DefineMigrationMapping.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, from_stable_id: @from, to_stable_id: @to, mapping_type: "evolved" }
        )

        assert_equal 1, mappings.count
        mapping = mappings.first
        assert_equal result[:mapping_id], mapping.mapping_id
        assert_equal "evolved", mapping.mapping_type
        assert mapping.requires_reassessment
        assert_equal 2, mapping.published_version
      end
    end

    should "edit in place when re-defining with the same mapping_id" do
      ActsAsTenant.with_tenant(@tenant) do
        first = Operations::Frameworks::DefineMigrationMapping.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, from_stable_id: @from, to_stable_id: @to, mapping_type: "evolved" }
        )

        Operations::Frameworks::DefineMigrationMapping.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, from_stable_id: @from, mapping_type: "archived", mapping_id: first[:mapping_id] }
        )

        assert_equal 1, mappings.count, "re-defining the same mapping_id must not duplicate"
        mapping = mappings.first
        assert_equal "archived", mapping.mapping_type
        assert_not mapping.requires_reassessment
        assert_nil mapping.to_stable_id
      end
    end
  end

  context "validation" do
    should "reject an evolved mapping with no surviving capability" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          Operations::Frameworks::DefineMigrationMapping.call(
            context: @admin_ctx,
            params: { framework_id: @framework_id, from_stable_id: @from, mapping_type: "evolved" }
          )
        end
        assert_match(/surviving capability/i, error.message)
        assert_equal 0, mappings.count
      end
    end

    # The forbidden half of the same rule. A survivor was previously accepted
    # and silently dropped, so a caller could believe it had mapped one.
    should "reject a non-survivor mapping that names a surviving capability" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          Operations::Frameworks::DefineMigrationMapping.call(
            context: @admin_ctx,
            params: { framework_id: @framework_id, from_stable_id: @from,
                      to_stable_id: @to, mapping_type: "archived" }
          )
        end
        assert_match(/archived mapping does not take a surviving capability/, error.message)
        assert_equal 0, mappings.count
      end
    end

    should "accept a non-survivor mapping with the survivor omitted" do
      ActsAsTenant.with_tenant(@tenant) do
        Operations::Frameworks::DefineMigrationMapping.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, from_stable_id: @from, mapping_type: "same" }
        )

        assert_equal "same", mappings.first.mapping_type
        assert_nil mappings.first.to_stable_id
      end
    end

    # How the web compacts an inapplicable field — it must read as absent, not
    # as a violation.
    should "accept a non-survivor mapping with an explicitly nil survivor" do
      ActsAsTenant.with_tenant(@tenant) do
        Operations::Frameworks::DefineMigrationMapping.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, from_stable_id: @from,
                    to_stable_id: nil, mapping_type: "archived" }
        )

        assert_equal "archived", mappings.first.mapping_type
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::DefineMigrationMapping.call(
            context: @member_ctx,
            params: { framework_id: @framework_id, from_stable_id: @from, mapping_type: "same" }
          )
        end
      end
    end
  end
end
