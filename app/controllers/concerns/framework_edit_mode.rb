# frozen_string_literal: true

# Reads the contributor's "Editing vs Suggesting" preference from a cookie
# and returns the matching symbol for {Frameworks::CommandHandler}.
#
# The cookie is written client-side by `edit_mode_toggle_controller.js`
# and persists for a year. Default is `:editing` — preserves the
# pre-toggle behaviour where changes auto-apply for users with approval
# authority.
#
# Included by the four inline-edit controllers
# ({Frameworks::IllustrationsController},
# {Frameworks::CapabilitiesController},
# {Frameworks::CategoriesController},
# {Frameworks::ExpectationsController}). The full-form
# {Frameworks::SuggestionsController} is intentionally NOT included — its
# create/delete endpoints are for proposing changes and always submit as
# pending regardless of the toggle.
#
module FrameworkEditMode
  extend ActiveSupport::Concern

  # @return [Symbol] `:suggesting` when the user has opted in via the UI
  #   toggle, `:editing` otherwise.
  def framework_edit_mode
    cookies[:framework_edit_mode] == "suggesting" ? :suggesting : :editing
  end
end
