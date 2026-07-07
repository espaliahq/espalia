# frozen_string_literal: true

# Manages framework-level configuration settings.
#
# Currently covers scoring thresholds; designed to be extended
# with additional setting sections in the future.
#
# Only accessible to tenant admins and global admins.
#
class Frameworks::SettingsController < ApplicationController
  before_action :set_framework

  # GET /frameworks/:framework_id/settings
  def show
    authorize @framework, :settings?
    render Views::Frameworks::SettingsView.new(
      framework: @framework,
      scoring_defaults: scoring_defaults,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: tenants_for_user
    )
  end

  # PATCH /frameworks/:framework_id/settings
  def update
    authorize @framework, :update_settings?
    settings = settings_params

    Operations::Frameworks::ConfigureScoringThresholds.call(
      context: pundit_user,
      params: {
        framework_id: @framework.framework_id,
        mastery_threshold: resolve_value(settings[:mastery_threshold], :mastery_threshold),
        meeting_expectation_threshold: resolve_value(settings[:meeting_expectation_threshold], :meeting_expectation_threshold),
        underperforming_threshold: resolve_value(settings[:underperforming_threshold], :underperforming_threshold),
        overperformance_cap: resolve_int_value(settings[:overperformance_cap], :overperformance_cap),
        deficit_threshold: resolve_value(settings[:deficit_threshold], :deficit_threshold)
      }
    )

    redirect_to framework_settings_path(@framework.framework_id),
                notice: "Scoring settings updated."
  rescue Operations::Base::ParameterError, RuntimeError => e
    redirect_to framework_settings_path(@framework.framework_id),
                alert: e.message
  end

  private

  def set_framework
    @framework = FrameworkState::Framework.find_by!(framework_id: params.expect(:framework_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to frameworks_path
  end

  # @return [ActionController::Parameters]
  def settings_params
    params.expect(settings: [ :mastery_threshold, :meeting_expectation_threshold,
                              :underperforming_threshold,
                              :overperformance_cap, :deficit_threshold ])
  end

  # Resolves a decimal param: blank string → nil (use system default), otherwise BigDecimal.
  #
  # @param value [String, nil]
  # @param _key [Symbol] unused, kept for clarity
  # @return [BigDecimal, nil]
  def resolve_value(value, _key)
    return nil if value.blank?

    BigDecimal(value.to_s)
  end

  # Resolves an integer param: blank string → nil (use system default), otherwise Integer.
  #
  # @param value [String, nil]
  # @param _key [Symbol] unused, kept for clarity
  # @return [Integer, nil]
  def resolve_int_value(value, _key)
    return nil if value.blank?

    value.to_i
  end

  # @return [Hash] system default values for scoring thresholds
  def scoring_defaults
    {
      mastery_threshold: PersonDevelopment::Scoring::DEFAULT_MASTERY_THRESHOLD,
      meeting_expectation_threshold: PersonDevelopment::Scoring::DEFAULT_MEETING_EXPECTATION_THRESHOLD,
      underperforming_threshold: PersonDevelopment::Scoring::DEFAULT_UNDERPERFORMING_THRESHOLD,
      overperformance_cap: PersonDevelopment::Scoring::DEFAULT_OVERPERFORMANCE_CAP,
      deficit_threshold: PersonDevelopment::Scoring::DEFAULT_DEFICIT_THRESHOLD
    }
  end

  # @return [Array<Tenant>]
  def tenants_for_user
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
