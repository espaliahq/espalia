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

  # Every mapping_type a retiring capability can be given.
  MAPPING_TYPES = %w[same evolved split archived new].freeze
  # mapping_types whose ratings warrant a reassessment flag downstream.
  REASSESS_TYPES = %w[evolved split].freeze
  # mapping_types that carry ratings to a surviving capability — they require a
  # `to_stable_id`. Derived from the same list, so the two halves of the rule
  # can never drift apart or leave a type unaccounted for.
  SURVIVOR_TYPES = %w[evolved split].freeze
  # The rest carry no ratings anywhere, so a survivor is meaningless for them
  # and supplying one is rejected rather than silently dropped.
  NON_SURVIVOR_TYPES = (MAPPING_TYPES - SURVIVOR_TYPES).freeze

  parameter :framework_id,   String, required: true
  parameter :from_stable_id, String, required: true
  parameter :mapping_type,   String, required: true, allowed: MAPPING_TYPES
  parameter :to_stable_id,   String
  parameter :mapping_id,     String
  parameter :reason,         String

  # Both messages reach the publish-review page as a flash, so they keep the
  # domain wording rather than the generic parameter-speak.
  SURVIVOR_REQUIRED_MESSAGE = ->(type) { "#{type} mapping requires a surviving capability (to_stable_id)" }
  SURVIVOR_FORBIDDEN_MESSAGE = ->(type) { "#{type} mapping does not take a surviving capability (to_stable_id)" }

  requires_when :to_stable_id, if: :mapping_type, in: SURVIVOR_TYPES,
                               message: SURVIVOR_REQUIRED_MESSAGE
  forbids_when :to_stable_id, if: :mapping_type, in: NON_SURVIVOR_TYPES,
                              message: SURVIVOR_FORBIDDEN_MESSAGE

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
