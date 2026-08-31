# frozen_string_literal: true

# Defines — or edits — a capability migration mapping for the current draft.
#
# Mappings are captured as-we-go when a capability is archived (see
# {Operations::Frameworks::ArchiveCapability}) and validated, possibly
# overridden, by the owner/editor on the publish-review screen. Re-submitting
# with the same `mapping_id` edits the existing mapping in place (the
# projection upserts by mapping_id); omitting it creates a new one — e.g. a
# second survivor for a `split`.
#
# Write — :mcp_client. It only stages migration intent into the open draft;
# the live impact happens at publish (which is :in_app). Restricted to
# owner/editor (FrameworkPolicy#define_migration_mapping?).
class Operations::Frameworks::DefineMigrationMapping < Operations::Base
  description "Define or edit a capability migration mapping for the current draft (owner/editor only)."
  category :write
  approval :mcp_client

  # mapping_types whose ratings warrant a reassessment flag downstream.
  REASSESS_TYPES = %w[evolved split].freeze
  # mapping_types that carry ratings to a surviving capability — they require
  # a `to_stable_id`; `archived` / `new` / `same` must not (it is ignored).
  SURVIVOR_TYPES = %w[evolved split].freeze

  parameter :framework_id,   String, required: true
  parameter :from_stable_id, String, required: true
  parameter :mapping_type,   String, required: true,
                                     allowed: %w[same evolved split archived new]
  parameter :to_stable_id,   String
  parameter :mapping_id,     String
  parameter :reason,         String

  requires_when :to_stable_id, if: :mapping_type, in: SURVIVOR_TYPES

  def policy_check
    authorize framework, :define_migration_mapping?
  end

  # @return [Hash] { framework_id:, mapping_id:, from_stable_id:, to_stable_id:, mapping_type: }
  def perform
    mapping_id = params[:mapping_id].presence || SecureRandom.uuid_v7

    Frameworks::CommandHandler.new.define_migration_mapping(
      framework.framework_id,
      mapping_id,
      params[:from_stable_id],
      params[:to_stable_id],
      params[:mapping_type],
      requires_reassessment: REASSESS_TYPES.include?(params[:mapping_type]),
      reason: params[:reason]
    )

    {
      framework_id: framework.framework_id,
      mapping_id: mapping_id,
      from_stable_id: params[:from_stable_id],
      to_stable_id: params[:to_stable_id],
      mapping_type: params[:mapping_type]
    }
  end

  private

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
