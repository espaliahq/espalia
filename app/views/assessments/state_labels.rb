# frozen_string_literal: true

# The word a performance state wears, for this tenant.
#
# The state itself is scoring policy and stays internal — `:mastering` in
# the engine, in `performance_state`, in the MCP payload, in
# `mastery_threshold`. The WORD is culture: "Mastering" reads oddly in
# plenty of teams beside "62% of the way to E4", and a team that would
# rather say "Advancing" is not asking for different scoring (#415).
#
# One reader, so the hero, the category header, the capability card, the
# chip bar, the glossary and the settings page cannot disagree about what a
# state is called.
#
# `:top_of_ladder` deliberately has no tenant override of its own: it is
# "meeting, with nothing above" and shares `:performing`'s word, so a tenant
# that renames one renames both rather than ending up with two words for
# one idea.
class Views::Assessments::StateLabels
  # The states a tenant can rename, mapped to the attribute holding it.
  CONFIGURABLE = {
    underperforming: :underperforming_label,
    progressing: :progressing_label,
    performing: :performing_label,
    top_of_ladder: :performing_label,
    mastering: :mastering_label,
    eligible: :eligible_label
  }.freeze

  # The label for one state.
  #
  # @param state [Symbol, String, nil] a `performance_state`
  # @param tenant [Tenant, nil] defaults to the current tenant
  # @return [String]
  def self.for(state, tenant: ActsAsTenant.current_tenant)
    key = state&.to_sym
    configured(key, tenant).presence || default_for(key)
  end

  # What an unknown or missing state reads as. Reachable from a stale
  # payload, so it says something true rather than raising.
  FALLBACK = "Below expectations"

  # The shipped word, ignoring any tenant override — for copy that has to
  # name the default ("falls back to Mastering").
  #
  # @param state [Symbol, nil]
  # @return [String]
  def self.default_for(state)
    return FALLBACK if state.blank?

    # A nil key would resolve to the whole `states` branch rather than the
    # default, so the lookup is guarded and its result type-checked.
    label = I18n.t("assessments.states.#{state}", default: nil)
    label.is_a?(String) ? label : FALLBACK
  end

  # @return [String, nil]
  def self.configured(state, tenant)
    attribute = CONFIGURABLE[state]
    return nil unless attribute && tenant.respond_to?(attribute)

    tenant.public_send(attribute)
  end
  private_class_method :configured
end
