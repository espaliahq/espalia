# frozen_string_literal: true

require "test_helper"

# The batch mapping Operation behind the review page's single save: rows are
# triaged (unchanged / undecided / incomplete / to save) and the saveable ones
# land in one atomic write.
class Operations::Frameworks::DefineMigrationMappingsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @legacy = SecureRandom.uuid_v7
      @tools = SecureRandom.uuid_v7
      @survivor = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      cat_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Eng")
      handler.add_capability_category(@framework_id, cat_id, "Thinking")
      handler.add_capability(@framework_id, SecureRandom.uuid_v7, @legacy, cat_id, "Legacy Systems")
      handler.add_capability(@framework_id, SecureRandom.uuid_v7, @tools, cat_id, "Old Tools")
      handler.add_capability(@framework_id, SecureRandom.uuid_v7, @survivor, cat_id, "Modern Platforms")
      handler.publish_version(@framework_id, "seed")  # v1
      handler.start_draft(@framework_id, 2, "seed")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def mappings
    FrameworkState::MigrationMapping.where(framework_id: @framework_id)
  end

  def save(rows, ctx: @admin_ctx)
    Operations::Frameworks::DefineMigrationMappings.call(
      context: ctx, params: { framework_id: @framework_id, mappings: rows }
    )
  end

  context "as a tenant admin" do
    should "save every complete row in one write and report the rest" do
      ActsAsTenant.with_tenant(@tenant) do
        result = save([
          { from_stable_id: @legacy, mapping_type: "evolved", to_stable_id: @survivor },
          { from_stable_id: @tools, mapping_type: "archived", to_stable_id: "" }
        ])

        assert_equal({ framework_id: @framework_id, saved: 2, skipped: 0, incomplete: [] }, result)
        assert_equal %w[archived evolved], mappings.pluck(:mapping_type).sort
        assert_equal 2, mappings.where(published_version: 2).count
      end
    end

    should "skip unchanged rows, leave undecided rows alone and name incomplete ones" do
      ActsAsTenant.with_tenant(@tenant) do
        save([ { from_stable_id: @tools, mapping_type: "archived" } ])
        mapping_id = mappings.first.mapping_id

        result = save([
          { from_stable_id: @tools, mapping_type: "archived", mapping_id: mapping_id },
          { from_stable_id: @legacy, mapping_type: "evolved", to_stable_id: "" },
          { from_stable_id: SecureRandom.uuid_v7, mapping_type: "" }
        ])

        assert_equal 0, result[:saved]
        assert_equal 2, result[:skipped]
        assert_equal [ "Legacy Systems" ], result[:incomplete]
        assert_equal 1, mappings.count, "nothing new was written"
      end
    end

    should "edit in place when a mapping_id is supplied" do
      ActsAsTenant.with_tenant(@tenant) do
        save([ { from_stable_id: @legacy, mapping_type: "evolved", to_stable_id: @survivor } ])
        mapping_id = mappings.first.mapping_id

        save([ { from_stable_id: @legacy, mapping_type: "archived", mapping_id: mapping_id } ])

        assert_equal 1, mappings.count
        assert_equal "archived", mappings.first.mapping_type
        assert_nil mappings.first.to_stable_id
      end
    end

    should "refuse the whole batch when a row breaks a rule, saving nothing" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          save([
            { from_stable_id: @tools, mapping_type: "archived" },
            { from_stable_id: @legacy, mapping_type: "archived", to_stable_id: @survivor }
          ])
        end
        assert_match(/does not take a surviving capability/, error.message)
        assert_equal 0, mappings.count

        error = assert_raises(Operations::Base::ParameterError) do
          save([ { from_stable_id: @legacy, mapping_type: "evolved", to_stable_id: @legacy } ])
        end
        assert_match(/own survivor/, error.message)
        assert_equal 0, mappings.count
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          save([ { from_stable_id: @tools, mapping_type: "archived" } ], ctx: @member_ctx)
        end
      end
    end
  end
end
