# frozen_string_literal: true

# @label Attention dot
class Kit::AttentionDotPreview < Lookbook::Preview
  # @param label text
  def playground(label: "needs your attention")
    render Components::Kit::AttentionDot.new(label)
  end

  # @!group In use

  # After a name in a list, as a Feedback / Evidence conversation row has it
  def after_a_name
    render_with_template
  end

  # @!endgroup
end
