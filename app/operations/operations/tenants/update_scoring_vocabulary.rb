# frozen_string_literal: true

# Rename the performance states for this tenant (#415).
#
# The state a score lands in is scoring policy and is not touched here —
# `:mastering` stays `:mastering` in the engine, in `performance_state` and
# in every MCP payload, and the thresholds that decide it live on the
# framework. This changes only the WORD a person reads, which is culture:
# "Mastering" reads oddly in plenty of teams beside "62% of the way to E4".
#
# Blank clears an override and the state falls back to the word GrowthOS
# ships, so a tenant stores only what it chose and a later change to the
# default still reaches them.
#
# Approval is :in_app for the same reason as the theme: from the web the
# settings form already IS the in-app surface, and from MCP the gate stops
# an agent loop quietly renaming the vocabulary a whole company reads.
class Operations::Tenants::UpdateScoringVocabulary < Operations::Base
  description "Rename the performance states for the active tenant (display labels only — " \
              "the scoring states and thresholds are unchanged). Blank restores the default word."
  category :write
  approval :in_app

  MAX_LENGTH = Tenant::STATE_LABEL_MAX_LENGTH

  parameter :underperforming_label, String
  parameter :progressing_label,     String
  parameter :performing_label,      String
  parameter :mastering_label,       String
  parameter :eligible_label,        String

  def policy_check
    authorize ActsAsTenant.current_tenant, :update_scoring_vocabulary?, policy_class: TenantPolicy
  end

  # @return [Hash] tenant_id, the attributes written, and the labels as they
  #   now read (the shipped word where an override was cleared), so a client
  #   sees the result rather than having to re-read it
  def perform
    validate_lengths!
    tenant = ActsAsTenant.current_tenant
    # `compact` drops the labels this call did not mention; an explicit ""
    # survives it, which is what clears an override.
    updates = params.slice(*Tenant::STATE_LABEL_ATTRIBUTES).compact
    tenant.update!(updates) if updates.any?

    { tenant_id: tenant.id, updated: updates.keys, labels: current_labels(tenant) }
  end

  private

  # At the boundary, so an over-long label is invalid *input* (-32602 over
  # MCP) rather than an internal error from the model's own validation.
  def validate_lengths!
    too_long = params.slice(*Tenant::STATE_LABEL_ATTRIBUTES)
      .select { |_, value| value.is_a?(String) && value.strip.length > MAX_LENGTH }
    return if too_long.empty?

    raise ParameterError,
      "#{too_long.keys.join(', ')}: must be #{MAX_LENGTH} characters or fewer"
  end

  def current_labels(tenant)
    Views::Assessments::StateLabels::CONFIGURABLE.keys.index_with do |state|
      Views::Assessments::StateLabels.for(state, tenant: tenant)
    end
  end
end
