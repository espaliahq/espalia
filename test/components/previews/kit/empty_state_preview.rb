# frozen_string_literal: true

# @label Empty state
class Kit::EmptyStatePreview < Lookbook::Preview
  # @param title text
  # @param body text
  # @param size select { choices: [page, panel] }
  def playground(title: "No frameworks yet",
                 body: "A framework sets out the roles, levels and capabilities people are rated on.",
                 size: :page)
    render Components::Kit::EmptyState.new(title: title, size: size.to_sym) { body.presence }
  end

  # Both sizes: title only, with a line of help, and with an action
  def sizes
    render_with_template(template: "kit/empty_state_preview/sizes")
  end
end
