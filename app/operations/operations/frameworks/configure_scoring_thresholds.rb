# frozen_string_literal: true

# Configures a framework's scoring thresholds — the levers behind the
# performance-state machine (see docs/architecture/scoring-model.md).
#
# **Full replacement**: every call sets the whole configuration. An omitted
# threshold reverts to the system default (the same semantics as clearing a
# field on the web settings form) — it does NOT keep its current value, so
# read the current configuration before a partial tweak. Tenant-settings
# write → :in_app approval.
class Operations::Frameworks::ConfigureScoringThresholds < Operations::Base
  description "Replace a framework's scoring-threshold configuration (tenant admin only). Omitted thresholds revert to system defaults — this is a full replacement, not a partial update."
  category :write
  approval :in_app

  # decimal(5,2) columns — anything at or beyond 1000 would overflow the
  # projection write; real threshold ratios sit around 0.5–2.0.
  DECIMAL_RANGE = (0..999.99)
  CAP_RANGE     = (0..100)

  parameter :framework_id,                  String, required: true
  parameter :mastery_threshold,             Numeric
  parameter :meeting_expectation_threshold, Numeric
  parameter :underperforming_threshold,     Numeric
  parameter :overperformance_cap,           Integer
  parameter :deficit_threshold,             Numeric

  # Framework scoring configuration is tenant administration.
  # @raise [Pundit::NotAuthorizedError]
  def policy_check
    authorize framework, :update_settings?
  end

  # @return [Hash] the stored configuration after the write — nil means
  #   "system default applies" for that threshold.
  def perform
    validate_ranges!
    validate_ordering!

    Frameworks::CommandHandler.new.configure_scoring_thresholds(
      framework.framework_id,
      mastery_threshold: decimal(:mastery_threshold),
      # The command/event key is promotion_score_threshold for legacy
      # reasons; the read model and every user-facing surface call it
      # meeting_expectation_threshold, so that's the parameter name.
      promotion_score_threshold: decimal(:meeting_expectation_threshold),
      underperforming_threshold: decimal(:underperforming_threshold),
      # overperformance_cap is NOT NULL on the read model, so "revert to
      # system default" writes the default value itself rather than nil.
      overperformance_cap: integer_or_default(
        :overperformance_cap, PersonDevelopment::Scoring::DEFAULT_OVERPERFORMANCE_CAP
      ),
      # nil = system default, like the three ratio thresholds — so a default
      # that moves with the code moves for every framework that never chose
      # a value, and a replay reproduces exactly what the event says.
      deficit_threshold: decimal(:deficit_threshold)
    )

    stored = framework.reload
    {
      framework_id: stored.framework_id,
      mastery_threshold: stored.mastery_threshold&.to_f,
      meeting_expectation_threshold: stored.meeting_expectation_threshold&.to_f,
      underperforming_threshold: stored.underperforming_threshold&.to_f,
      overperformance_cap: stored.overperformance_cap,
      deficit_threshold: stored.deficit_threshold&.to_f
    }
  end

  private

  # Out-of-range values must classify as invalid params — unchecked they
  # only fail at the projection's decimal(5,2) write (→ internal error).
  def validate_ranges!
    %i[mastery_threshold meeting_expectation_threshold
       underperforming_threshold deficit_threshold].each do |key|
      value = params[key]
      next if value.nil? || DECIMAL_RANGE.cover?(value)

      raise Operations::Base::ParameterError,
            "#{key} must be between #{DECIMAL_RANGE.min} and #{DECIMAL_RANGE.max}"
    end

    cap = params[:overperformance_cap]
    return if cap.nil? || CAP_RANGE.cover?(cap)

    raise Operations::Base::ParameterError,
          "overperformance_cap must be between #{CAP_RANGE.min} and #{CAP_RANGE.max}"
  end

  # The state machine evaluates underperforming → meeting → mastery in a fixed
  # order, so an inverted configuration silently produces nonsense states.
  # Resolve each omitted value to its default first — that is what the
  # engine will run with.
  def validate_ordering!
    return if PersonDevelopment::Scoring.thresholds_ordered?(
      underperforming: params[:underperforming_threshold],
      meeting: params[:meeting_expectation_threshold],
      mastery: params[:mastery_threshold]
    )

    raise Operations::Base::ParameterError,
          "thresholds must be ordered underperforming < meeting_expectation < mastery " \
          "(omitted values take their defaults)"
  end

  # Store decimals as BigDecimal so the event payload round-trips without
  # float artefacts (0.1 + 0.2 class of noise) into the decimal column.
  def decimal(key)
    value = params[key]
    value.nil? ? nil : BigDecimal(value.to_s)
  end

  def integer_or_default(key, default)
    params[key] || default
  end

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
