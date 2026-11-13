# frozen_string_literal: true

# The Units view's right-hand column. The activity sidebar (5.4) renders
# inside it; it sits beside the opened unit on a wide screen and below it
# on a phone.
class Views::Tenant::OrgGraph::Sidebar < Views::Base
  ID = "org-graph-sidebar"

  # @param title [String]
  def initialize(title:)
    @title = title
  end

  def view_template(&)
    aside(
      id: ID,
      class: "lg:w-72 lg:shrink-0 lg:self-start bg-default border border-default rounded-2xl p-4",
      aria: { labelledby: "#{ID}-title" }
    ) do
      h2(id: "#{ID}-title", class: "text-xs font-semibold uppercase tracking-wide text-muted") { @title }
      div(class: "mt-3", &)
    end
  end
end
