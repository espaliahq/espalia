# frozen_string_literal: true

# One menu for many kebabs, for a list or grid with a ⋮ on every row, where a
# {Kit::Dropdown} per row would ship every menu's markup with the page. Each
# row gets a bare {Trigger} carrying its own values, the page renders each
# kind of menu once as a `<template>`, and the `delegated-menu` controller,
# mounted once on a container, builds the menu when a trigger opens it.
#
# An item's attribute names a trigger value as `{name}`, filled from the
# trigger's `data-menu-<name>` on open. The controller moves between items with
# the arrow keys, Home and End, and closes on Escape, Tab, an outside click or
# a dialog opening.
#
# @example
#   div(data: Components::Kit::DelegatedMenu.root_data) do
#     render Components::Kit::DelegatedMenu.new(kind: "position") do |menu|
#       menu.item(data: { action: "click->modal#open", modal_target_id: "edit-modal", edit_url: "{url}" }) { "Edit…" }
#       menu.item(tone: :danger, data: { … }) { "Close…" }
#     end
#     rows.each do |row|
#       render Components::Kit::DelegatedMenu::Trigger.new(label: "Actions for #{row.name}", kind: "position",
#                                                          values: { url: row_path(row) })
#     end
#   end
class Components::Kit::DelegatedMenu < Components::Base
  CONTROLLER = "delegated-menu"

  # The container's `data:`, mounting the controller and its window listeners.
  # @param controller [String] a controller that extends `delegated-menu`, such as the explorer's
  # @return [Hash]
  def self.root_data(controller: CONTROLLER)
    { controller:, action: "keydown.esc@window->#{controller}#escape keydown->#{controller}#keydown " \
                           "click@window->#{controller}#clickOutside" }
  end

  # @param kind [String] the `kind:` of the triggers this menu serves
  def initialize(kind:)
    @kind = kind
    @items = []
  end

  # One entry in the menu.
  # @param tone [Symbol] :neutral or :danger
  # @param data [Hash] the entry's `data-*`, with `{name}` for a trigger value
  def item(tone: :neutral, data: {}, &content)
    @items << [ tone, data, content ]
    nil
  end

  def view_template(&)
    vanish(&)
    template(data: { delegated_menu_kind: @kind }) do
      @items.each do |tone, data, content|
        button(type: "button", role: "menuitem", class: Components::Kit::Dropdown.item_classes(tone:), data:, &content)
      end
    end
  end

  # The ⋮ on a row. `.kit-menu-trigger` is one class rather than a utility
  # string, since it repeats on every row (tailwindcss.md).
  class Trigger < Components::Base
    CLASSES = "kit-menu-trigger"

    # @param label [String] what the trigger and its menu are called, e.g. "Actions for Designer"
    # @param kind [String] which menu it opens
    # @param values [Hash{Symbol => String, Numeric, Boolean, nil}] filled into the menu's `{name}`s; true is a bare
    #   attribute, and nil and false are left out
    # @param controller [String] the controller mounted on the container
    # @param attrs [Hash] merged onto the button; a `class:` replaces the default chrome
    def initialize(label:, kind:, values: {}, controller: CONTROLLER, **attrs)
      @label = label
      @kind = kind
      @values = values
      @controller = controller
      @attrs = attrs
    end

    def view_template
      button(type: "button", class: @attrs.fetch(:class, CLASSES), aria: { haspopup: "menu", expanded: "false", label: @label },
             data: { **@attrs.fetch(:data, {}), action: "#{@controller}#toggle", menu: @kind, **menu_values },
             **@attrs.except(:class, :data)) do
        icon(:kebab)
      end
    end

    private

    # A Symbol is stringified, since Phlex would dasherize it.
    def menu_values = @values.to_h { |name, value| [ :"menu_#{name}", value.is_a?(Symbol) ? value.to_s : value ] }
  end
end
