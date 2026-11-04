# frozen_string_literal: true

# @label Segmented control
class Kit::SegmentedControlPreview < Lookbook::Preview
  SegmentedControl = Components::Kit::SegmentedControl

  # @param size select { choices: [sm, md] }
  # @param fill toggle
  # @param selected select { choices: [Auto, Light, Dark] }
  # @param disabled toggle
  def playground(size: :md, fill: false, selected: "Light", disabled: false)
    render SegmentedControl.new(label: "Appearance", size: size.to_sym, fill: fill) do |control|
      %w[Auto Light Dark].each { |label| control.segment(label, selected: label == selected, disabled: disabled) }
    end
  end

  # @!group In use

  # The activity feed's focus mode, at the small size
  def small
    render SegmentedControl.new(label: "Activity feed focus mode", size: :sm) do |control|
      control.segment("Highlight")
      control.segment("Filter", selected: true)
    end
  end

  # The framework header's edit mode, with each segment's tooltip
  def medium
    render SegmentedControl.new(label: "Edit mode") do |control|
      control.segment("Editing", selected: true, title: "Changes you make apply immediately.")
      control.segment("Suggesting", title: "Changes land as pending suggestions for review.")
    end
  end

  # Appearance in the user menu: the segments share the width and are menuitemradio, since a menu holds only menu items
  def in_a_menu
    render_with_template
  end

  # A dot on a view that holds something needing attention, as the Feedback / Evidence page's grouping does
  def marked_segment
    render SegmentedControl.new(label: "Group conversations", size: :sm) do |control|
      control.segment("By report", selected: true, href: "#by-report")
      control.segment("By person", href: "#by-person", marked: "needs your attention")
    end
  end

  # One segment unavailable
  def disabled_segment
    render SegmentedControl.new(label: "Period") do |control|
      control.segment("This week")
      control.segment("This cycle", selected: true)
      control.segment("All time", disabled: true)
    end
  end

  # @!endgroup
end
