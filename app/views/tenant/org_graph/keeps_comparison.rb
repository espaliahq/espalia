# frozen_string_literal: true

# Carries the comparison window (#139) through the Units view's links and
# forms, so no action there throws someone comparing with a date back to
# today (#156). A link adds `**compared` to its params; a form renders
# `comparison_fields`.
module Views::Tenant::OrgGraph::KeepsComparison
  # A view rendered outside an Org Graph controller has no window.
  #
  # @return [Hash{Symbol => String}] from, to and by, or empty
  def compared = view_context.try(:comparison_params) || {}

  # Hidden fields carrying the window through a form.
  def comparison_fields = compared.each { |name, value| input(type: "hidden", name: name.to_s, value:) }
end
