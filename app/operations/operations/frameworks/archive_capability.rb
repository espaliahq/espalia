# frozen_string_literal: true

# Archives a capability and, in the same action, records the migration
# mapping for its existing ratings — the "map as-we-go" flow. The person
# archiving makes the call with the freshest context; the owner/editor
# validates (and may override) it on the publish-review screen.
#
# A capability that was added in the current draft has nothing to migrate,
# so the caller omits the mapping params and only the archive is dispatched.
# For a pre-draft capability the caller supplies `mapping_type` (+ a survivor
# `to_stable_id` for same/evolved/split); the mapping is keyed off the
# capability's own stable_id. Archiving also auto-opens a draft if none is
# open (see Frameworks::Aggregate#ensure_draft_in_progress!).
#
# Write — :mcp_client. It stages a structural change into the open draft;
# the live impact (and the assessment migration) happens at publish, which
# is :in_app. Restricted to edit-rights holders (FrameworkPolicy#archive_capability?).
class Operations::Frameworks::ArchiveCapability < Operations::Base
  description "Archive a capability, optionally recording its migration mapping (owner/editor/lead only)."
  category :write
  approval :mcp_client

  parameter :framework_id,  String, required: true
  parameter :capability_id, String, required: true
  parameter :reason,        String
  parameter :mapping_type,  String, allowed: %w[same evolved split archived new]
  parameter :to_stable_id,  String

  def policy_check
    authorize framework, :archive_capability?
  end

  # @return [Hash] { framework_id:, capability_id:, stable_id:, mapping_type: }
  def perform
    # Validate the mapping combo BEFORE archiving so we never persist the
    # archive and then fail on the mapping (which would leave the capability
    # archived without a mapping). Mirrors DefineMigrationMapping's guard.
    if Operations::Frameworks::DefineMigrationMapping::SURVIVOR_TYPES.include?(params[:mapping_type]) &&
       params[:to_stable_id].blank?
      raise Operations::Base::ParameterError,
            "#{params[:mapping_type]} mapping requires a surviving capability (to_stable_id)"
    end

    handler = Frameworks::CommandHandler.new
    handler.archive_capability(framework.framework_id, capability.capability_id, reason: params[:reason])

    define_mapping if params[:mapping_type].present?

    {
      framework_id: framework.framework_id,
      capability_id: capability.capability_id,
      stable_id: capability.stable_id,
      mapping_type: params[:mapping_type]
    }
  end

  private

  def define_mapping
    Operations::Frameworks::DefineMigrationMapping.call(
      context: context,
      params: {
        framework_id: framework.framework_id,
        from_stable_id: capability.stable_id,
        to_stable_id: params[:to_stable_id],
        mapping_type: params[:mapping_type]
      }
    )
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end

  # Scope the capability lookup through its category to the authorized
  # framework — a tenant can hold several frameworks, so capability_id alone
  # is not safe (see mcp-server.md, hard-won lesson 5).
  def capability
    @capability ||= FrameworkState::Capability
      .joins(:category)
      .where(framework_capability_categories: { framework_id: framework.framework_id })
      .find_by!(capability_id: params[:capability_id])
  end
end
