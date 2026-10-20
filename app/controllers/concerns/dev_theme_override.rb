# frozen_string_literal: true

# Development only: `?theme=bento` and `?scheme=dark` (or `light`) preview the
# app in any theme and colour scheme before tenants and people can choose one.
# The choice sticks in a cookie until `?theme=default` or `?scheme=auto`.
module DevThemeOverride
  extend ActiveSupport::Concern

  THEMES = %w[bento].freeze
  SCHEMES = %w[light dark].freeze

  included do
    before_action :remember_dev_theme_override
    helper_method :dev_theme_override, :dev_scheme_override
  end

  private

  # @return [String, nil] the preset to apply as <html data-theme>
  def dev_theme_override
    cookies[:dev_theme].presence_in(THEMES) if Rails.env.development?
  end

  # @return [String, nil] the scheme to apply as <html data-scheme>
  def dev_scheme_override
    cookies[:dev_scheme].presence_in(SCHEMES) if Rails.env.development?
  end

  # @return [void]
  def remember_dev_theme_override
    return unless Rails.env.development?

    remember_override(:dev_theme, params[:theme], THEMES)
    remember_override(:dev_scheme, params[:scheme], SCHEMES)
  end

  # Any value outside the allowed list (`default`, `auto`) clears the override.
  #
  # @return [void]
  def remember_override(cookie, value, allowed)
    return if value.blank?

    if allowed.include?(value)
      cookies[cookie] = value
    else
      cookies.delete(cookie)
    end
  end
end
