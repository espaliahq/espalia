# frozen_string_literal: true

# A person's own Auto / Light / Dark choice, from the user menu. The menu
# applies the new `data-scheme` to the page itself, so a Turbo or fetch
# request gets 204 and nothing to render; a plain form post goes back.
class Settings::ColorSchemesController < ApplicationController
  # PATCH /settings/color_scheme
  def update
    authorize :color_scheme, :update?

    if current_user.update(color_scheme: params.expect(:color_scheme))
      forget_dev_scheme_override
      respond_to do |format|
        format.html { redirect_back_or_to root_path }
        format.any(:turbo_stream, :json) { head :no_content }
      end
    else
      respond_to do |format|
        format.html { redirect_back_or_to root_path, alert: "Choose Auto, Light or Dark." }
        format.any(:turbo_stream, :json) { head :unprocessable_content }
      end
    end
  end
end
