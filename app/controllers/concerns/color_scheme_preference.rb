# frozen_string_literal: true

# The `<html data-scheme>` value for this request: the signed-in person's
# choice, or nil for Auto so the page follows the operating system. In
# development a `?scheme=` override ({DevThemeOverride}) wins.
module ColorSchemePreference
  extend ActiveSupport::Concern

  included do
    helper_method :html_data_scheme
  end

  private

  # @return [String, nil] "light", "dark" or nil
  def html_data_scheme
    dev_scheme_override || current_user&.data_scheme
  end
end
