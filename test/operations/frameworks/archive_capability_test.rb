# frozen_string_literal: true

require "test_helper"

# End-to-end check of the as-we-go archive flow: archiving a pre-draft
# capability auto-opens a draft, records the migration mapping in the same
# action, and (once published) marks the capability archived. Without a
# mapping the publish gate blocks — proving why mapping-as-we-go matters.
class Operations::Frameworks::ArchiveCapabilityTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    @collab_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_person = create(:person, tenant: @tenant, email: @admin_user.email)
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin, person: @admin_person)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      # A plain collaborator: suggest rights, but no approval authority on
      # capabilities — so their archive lands as a suggestion, not a direct one.
      @collab_person = create(:person, tenant: @tenant)
      @collab_tu = create(:tenant_user, tenant: @tenant, user: @collab_user, role: :member, person: @collab_person)

      @framework_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      @survivor_stable = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, cat_id, "Thinking")
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, cat_id, "Legacy Systems")
      handler.add_capability(@framework_id, SecureRandom.uuid_v7, @survivor_stable, cat_id, "Platform Eng")
      handler.add_collaborator(@framework_id, @collab_person.id.to_s, "collaborator", added_by: @collab_person.id.to_s)
      handler.publish_version(@framework_id, "seed") # v1; no draft, caps are pre-draft
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: @admin_person)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
    @collab_ctx = AuthorizationContext.new(user: @collab_user, tenant_user: @collab_tu, person: @collab_person)
  end

  def pending_archive_suggestions
    FrameworkState::SuggestedEdit.where(framework_id: @framework_id, kind: "delete",
                                        target_entity_id: @cap_id, status: "pending")
  end

  def framework
    FrameworkState::Framework.find_by!(framework_id: @framework_id)
  end

  context "as a tenant admin" do
    should "archive with a mapping, auto-open a draft, and apply on publish" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::ArchiveCapability.call(
          context: @admin_ctx,
          params: {
            framework_id: @framework_id, capability_id: @cap_id, reason: "Retired",
            mapping_type: "evolved", to_stable_id: @survivor_stable
          }
        )
        assert_equal @cap_id, result[:capability_id]
        assert_equal "evolved", result[:mapping_type]

        # Draft auto-opened; the mapping is recorded for the draft version.
        assert framework.draft_in_progress
        assert_equal 2, framework.draft_version
        mapping = FrameworkState::MigrationMapping.find_by(
          framework_id: @framework_id, from_stable_id: result[:stable_id]
        )
        assert_not_nil mapping
        assert_equal "evolved", mapping.mapping_type
        assert_equal @survivor_stable, mapping.to_stable_id

        # Archive is shape-changing — deferred in the published view until publish.
        assert_equal "active", FrameworkState::Capability.find_by(capability_id: @cap_id).status

        Frameworks::CommandHandler.new.publish_version(@framework_id, "seed")
        assert_equal "archived", FrameworkState::Capability.find_by(capability_id: @cap_id).status
      end
    end

    should "archive without a mapping but then block publish (mapping required)" do
      ActsAsTenant.with_tenant(@tenant) do
        Operations::Frameworks::ArchiveCapability.call(
          context: @admin_ctx, params: { framework_id: @framework_id, capability_id: @cap_id, reason: "Retired" }
        )

        error = assert_raises(RuntimeError) do
          Frameworks::CommandHandler.new.publish_version(@framework_id, "seed")
        end
        assert_match(/lack migration mappings/i, error.message)
      end
    end
  end

  context "archiving a draft-added capability" do
    should "resolve it from the graph (deferred from the read model) and archive it" do
      ActsAsTenant.with_tenant(@tenant) do
        new_cap_id = SecureRandom.uuid_v7
        Frameworks::CommandHandler.new.add_capability(
          @framework_id, new_cap_id, SecureRandom.uuid_v7,
          FrameworkState::CapabilityCategory.first.category_id, "Draft Cap"
        )
        # Shape-changing add — deferred from the published read model.
        assert_nil FrameworkState::Capability.find_by(capability_id: new_cap_id)

        result = Operations::Frameworks::ArchiveCapability.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, capability_id: new_cap_id, reason: "oops" }
        )
        assert_equal new_cap_id, result[:capability_id]

        # Added and archived in the same draft needs no migration mapping — publish succeeds.
        assert_nothing_raised { Frameworks::CommandHandler.new.publish_version(@framework_id, "seed") }
      end
    end
  end

  context "as an authority-holder in suggesting mode" do
    should "propose the archive instead of applying it directly" do
      ActsAsTenant.with_tenant(@tenant) do
        # @admin_ctx CAN approve — proves the suggesting toggle overrides authority.
        result = Operations::Frameworks::ArchiveCapability.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, capability_id: @cap_id, reason: "Retire", mode: "suggesting" }
        )

        assert_equal false, result[:archived]
        assert_equal 1, pending_archive_suggestions.count
        # Nothing archived, no draft opened — it's only a proposal.
        assert_not framework.draft_in_progress
        assert_equal "active", FrameworkState::Capability.find_by(capability_id: @cap_id).status
      end
    end
  end

  context "as a collaborator without approval authority (editing mode)" do
    should "propose the archive (no authority to apply directly)" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::ArchiveCapability.call(
          context: @collab_ctx,
          params: { framework_id: @framework_id, capability_id: @cap_id, reason: "Retire", mode: "editing" }
        )

        assert_equal false, result[:archived]
        assert_equal 1, pending_archive_suggestions.count
      end
    end

    should "apply the same archive once an approver approves the proposal" do
      ActsAsTenant.with_tenant(@tenant) do
        Operations::Frameworks::ArchiveCapability.call(
          context: @collab_ctx,
          params: { framework_id: @framework_id, capability_id: @cap_id, reason: "Retire", mode: "editing" }
        )
        suggestion_id = pending_archive_suggestions.first.suggestion_id

        Operations::Frameworks::ApproveSuggestion.call(
          context: @admin_ctx, params: { framework_id: @framework_id, suggestion_id: suggestion_id }
        )

        # Approval runs the very same archive command — a CapabilityArchived
        # event is staged into the (now auto-opened) draft. (Publishing it would
        # need a migration mapping; that's the publish gate's job, tested above.)
        assert framework.draft_in_progress
        stream = Rails.configuration.event_store.read
          .stream(EventStreamNaming.framework_stream(@framework_id)).to_a
        assert(stream.any? { |e|
          e.is_a?(Frameworks::Events::CapabilityArchived) && e.data[:capability_id] == @cap_id
        }, "expected the approval to stage a CapabilityArchived for the capability")
      end
    end
  end

  context "as a plain tenant member (no suggest rights)" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::ArchiveCapability.call(
            context: @member_ctx, params: { framework_id: @framework_id, capability_id: @cap_id, reason: "x" }
          )
        end
      end
    end
  end
end
