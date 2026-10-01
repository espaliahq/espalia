# frozen_string_literal: true

# Generic hierarchical tree with checkboxes and solo mode.
#
# Renders a collapsible tree where each node has a checkbox for selection
# and an optional solo button. Purely structural HTML — all interaction
# logic lives in the Stimulus `tree` controller.
#
# @example
#   render Components::Kit::TreeNav.new(
#     nodes: [
#       { id: "rf1", label: "Engineering", children: [
#         { id: "r1", label: "Software Engineer", checked: true, data: { track: "ic" } },
#         { id: "r2", label: "Engineering Manager", checked: false, data: { track: "management" } }
#       ]}
#     ]
#   )
#
class Components::Kit::TreeNav < Components::Base
  # @param nodes [Array<Hash>] tree structure
  #   Each node: { id:, label:, children: [{ id:, label:, checked:, data: {} }], expanded: true }
  def initialize(nodes:)
    @nodes = nodes
  end

  def view_template
    nav(class: "space-y-1", role: "tree") do
      @nodes.each { |node| group_node(node) }
    end
  end

  private

  def group_node(node)
    expanded = node.fetch(:expanded, true)
    children = node.fetch(:children, [])
    all_checked = children.all? { |c| c[:checked] }
    some_checked = children.any? { |c| c[:checked] }

    div(
      class: "select-none",
      data: { tree_target: "group", family_id: node[:id] }
    ) do
      # Group header (family-level)
      div(class: "flex items-center gap-2 px-3 py-1.5 rounded-md " \
                 "hover:bg-gray-100 dark:hover:bg-gray-800 cursor-pointer group") do
        # Disclosure triangle
        button(
          type: "button",
          class: "w-4 h-4 flex items-center justify-center text-gray-400 " \
                 "hover:text-gray-600 dark:hover:text-gray-300 transition-transform",
          data: { action: "tree#toggleGroup", family_id: node[:id] },
          aria: { expanded: expanded }
        ) do
          svg(
            class: "w-3 h-3 #{expanded ? 'rotate-90' : ''} transition-transform",
            fill: "none", viewBox: "0 0 24 24", stroke: "currentColor", stroke_width: "2"
          ) do |s|
            s.path(d: "M9 5l7 7-7 7")
          end
        end

        # Family checkbox
        input(
          type: "checkbox",
          class: "rounded-xs border-gray-300 dark:border-gray-600 text-primary " \
                 "focus:ring-primary dark:bg-gray-700",
          checked: all_checked,
          indeterminate: some_checked && !all_checked,
          data: { action: "tree#toggleFamily", family_id: node[:id], tree_target: "familyCheckbox" }
        )

        # Label
        span(class: "text-sm font-medium text-gray-700 dark:text-gray-300 flex-1 truncate") do
          node[:label]
        end

        # Child count badge
        span(class: "text-xs text-gray-600 dark:text-gray-300") do
          children.size.to_s
        end
      end

      # Children (roles)
      div(
        class: "ml-6 space-y-0.5 #{expanded ? '' : 'hidden'}",
        data: { tree_target: "childList", family_id: node[:id] }
      ) do
        children.each { |child| leaf_node(child) }
      end
    end
  end

  def leaf_node(node)
    data_attrs = { action: "tree#toggleRole", role_id: node[:id], tree_target: "role" }
    data_attrs.merge!(node[:data] || {})

    div(
      class: "flex items-center gap-2 px-3 py-1 rounded-md " \
             "hover:bg-gray-100 dark:hover:bg-gray-800 group",
      data: data_attrs
    ) do
      input(
        type: "checkbox",
        class: "rounded-xs border-gray-300 dark:border-gray-600 text-primary " \
               "focus:ring-primary dark:bg-gray-700",
        checked: node[:checked],
        data: { role_id: node[:id] }
      )

      span(class: "text-sm text-gray-600 dark:text-gray-400 flex-1 truncate") do
        node[:label]
      end

      # Solo button (hidden until hover)
      button(
        type: "button",
        class: "opacity-0 group-hover:opacity-100 px-1.5 py-0.5 text-xs rounded-sm " \
               "bg-gray-200 dark:bg-gray-700 text-gray-600 dark:text-gray-300 " \
               "hover:bg-primary/20 hover:text-primary-ink transition-opacity",
        data: { action: "tree#solo", role_id: node[:id] },
        title: "Solo — focus on this role only"
      ) { "solo" }
    end
  end
end
