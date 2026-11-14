# frozen_string_literal: true

# A plain form with the CSRF token and the method spoof, for the settings
# panels' small forms.
module Views::Tenant::OrgGraph::Settings::FormHelpers
  private

  # @param url [String]
  # @param method [Symbol] :post, :patch or :delete
  # @param attrs [Hash] passed through to the form
  def settings_form(url, method: :post, **attrs, &)
    form(action: url, method: "post", **attrs) do
      input(type: "hidden", name: "_method", value: method.to_s.upcase) unless method == :post
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      yield
    end
  end
end
