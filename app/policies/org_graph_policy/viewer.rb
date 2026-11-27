# frozen_string_literal: true

# What the Units view shows its viewer beyond the units themselves, resolved
# from {OrgGraphPolicy} so the views only read flags. An admin sees it in the
# admin shell; anyone else {OrgGraphPolicy#show_units?} admits, in the app's.
# People's drawers, stale facts and the organisation's activity are for
# admins and editors.
class OrgGraphPolicy::Viewer
  # @param policy [OrgGraphPolicy]
  def initialize(policy)
    @admin = policy.edit_settings?
    @editor = policy.edit_structure?
  end

  # @return [Boolean] whether the view sits in the admin shell, with Settings
  def admin? = @admin

  # @return [Boolean] whether people open a drawer, and the organisation's activity shows
  def editor? = @editor
end
