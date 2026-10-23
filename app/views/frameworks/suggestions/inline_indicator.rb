# frozen_string_literal: true

# Small badge indicating the number of pending suggestions on a framework
# entity. Renders nothing when count is zero.
#
# Designed to sit inline in matrix cells, illustration frames, capability
# headers, etc.
#
class Views::Frameworks::Suggestions::InlineIndicator < Views::Base
  # @param count [Integer] number of pending suggestions
  def initialize(count:)
    @count = count
  end

  def view_template
    return if @count.zero?

    render Components::Kit::Badge.new("#{@count} pending", tone: :warning,
                                      title: "#{@count} pending #{'suggestion'.pluralize(@count)}")
  end
end
