# frozen_string_literal: true

# Framework-specific role tree for the explorer left pane.
#
# Three-level hierarchy: Department → Role Family → Role.
# If role families have no department set, they appear ungrouped at the top.
#
class Views::Frameworks::Explorer::RoleTree < Views::Base
  TRACK_OPTIONS = [
    { value: "both", label: "All" },
    { value: "ic", label: "IC" },
    { value: "management", label: "Mgmt" }
  ].freeze

  # @param role_families [Array<FrameworkState::RoleFamily>] eager-loaded with roles
  # @param selected_role_ids [Array<String>] currently selected role UUIDs
  # @param track_filter [String] "ic", "management", or "both"
  def initialize(role_families:, selected_role_ids:, track_filter:)
    @role_families = role_families
    @selected_role_ids = selected_role_ids
    @track_filter = track_filter
  end

  def view_template
    div(class: "flex flex-col h-full") do
      header_section
      solo_hint
      div(class: "flex-1 overflow-y-auto p-3") do
        nav(class: "space-y-1", role: "tree") do
          departments_with_families.each do |dept_name, families|
            department_group(dept_name, families)
          end
        end
      end
    end
  end

  private

  # ── Header ──

  def header_section
    div(class: "p-3 border-b border-gray-200 dark:border-gray-700 space-y-3") do
      div(class: "flex items-center justify-between") do
        h3(class: "text-sm font-semibold text-gray-900 dark:text-white") { "Roles" }
        div(class: "flex items-center gap-3") do
          button(
            type: "button",
            class: "text-xs text-primary hover:text-primary/80",
            data: { action: "tree#showAll" }
          ) { "Show All" }
          button(
            type: "button",
            class: "text-xs text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-200",
            data: { action: "tree#clearAll" }
          ) { "Clear All" }
        end
      end
      track_filter_buttons
    end
  end

  # One-time discovery tip for the per-role "solo" button, whose hover-only
  # affordance is otherwise easy to miss. The tree controller removes this on
  # connect when the user has dismissed it before (persisted in localStorage).
  def solo_hint
    div(
      class: "flex items-start gap-2 px-3 py-2 text-xs " \
             "bg-primary/5 text-gray-600 dark:text-gray-300 " \
             "border-b border-gray-200 dark:border-gray-700",
      data: { tree_target: "hint" }
    ) do
      span(class: "flex-1 leading-snug") do
        plain "Tip: hover a role and click "
        span(class: "font-semibold text-primary") { "Solo" }
        plain " to focus on just that one."
      end
      button(
        type: "button",
        class: "shrink-0 text-gray-400 hover:text-gray-600 dark:hover:text-gray-300",
        aria: { label: "Dismiss tip" },
        data: { action: "tree#dismissHint" }
      ) do
        svg(
          class: "w-3.5 h-3.5", fill: "none", viewBox: "0 0 24 24",
          stroke: "currentColor", stroke_width: "2"
        ) do |s|
          s.path(d: "M6 18L18 6M6 6l12 12")
        end
      end
    end
  end

  def track_filter_buttons
    div(class: "flex gap-1") do
      TRACK_OPTIONS.each do |opt|
        active = @track_filter == opt[:value]
        button(
          type: "button",
          class: track_button_classes(active),
          data: { action: "tree#filterTrack", track: opt[:value], tree_target: "trackButton" }
        ) { opt[:label] }
      end
    end
  end

  def track_button_classes(active)
    base = "flex-1 px-3 py-1.5 text-xs font-medium rounded-md transition-colors"
    if active
      "#{base} bg-primary text-white"
    else
      "#{base} bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-400 " \
      "hover:bg-gray-200 dark:hover:bg-gray-700"
    end
  end

  # ── Tree Structure ──

  # Groups role families by department.
  # Families without a department go under nil key.
  #
  # @return [Array<Array>] ordered pairs of [dept_name, families]
  def departments_with_families
    grouped = @role_families
      .select { |rf| rf.roles.any? { |r| track_visible?(r) } }
      .group_by { |rf| rf.respond_to?(:department) ? rf.department : nil }

    # Sort: named departments first (alphabetically), then ungrouped
    grouped.sort_by { |dept, _| dept || "zzz" }
  end

  def department_group(dept_name, families)
    if dept_name.present?
      # Department header with collapsible content
      div(class: "mb-2") do
        div(class: "px-3 py-1.5 text-xs font-bold text-gray-600 dark:text-gray-300 uppercase tracking-wider") do
          dept_name
        end
        div(class: "space-y-0.5") do
          families.sort_by(&:name).each { |rf| family_group(rf) }
        end
      end
    else
      # Ungrouped families (no department)
      families.sort_by(&:name).each { |rf| family_group(rf) }
    end
  end

  def family_group(role_family)
    visible_roles = role_family.roles.select { |r| track_visible?(r) }.sort_by(&:name)
    return if visible_roles.empty?

    all_checked = visible_roles.all? { |r| role_checked?(r) }
    some_checked = visible_roles.any? { |r| role_checked?(r) }

    div(
      class: "select-none",
      data: { tree_target: "group", family_id: role_family.role_family_id }
    ) do
      # Family header
      div(class: "flex items-center gap-2 px-3 py-1.5 rounded-md " \
                 "hover:bg-gray-100 dark:hover:bg-gray-800 cursor-pointer group") do
        # Disclosure triangle
        button(
          type: "button",
          class: "w-4 h-4 flex items-center justify-center text-gray-400 " \
                 "hover:text-gray-600 dark:hover:text-gray-300 transition-transform",
          data: { action: "tree#toggleGroup", family_id: role_family.role_family_id },
          aria: { expanded: true }
        ) do
          svg(
            class: "w-3 h-3 rotate-90 transition-transform",
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
          data: { action: "change->tree#toggleFamily", family_id: role_family.role_family_id, tree_target: "familyCheckbox" }
        )

        span(class: "text-sm font-medium text-gray-700 dark:text-gray-300 flex-1 truncate") do
          role_family.name
        end

        span(class: "text-xs text-gray-600 dark:text-gray-300") { visible_roles.size.to_s }
      end

      # Roles
      div(
        class: "ml-6 space-y-0.5",
        data: { tree_target: "childList", family_id: role_family.role_family_id }
      ) do
        visible_roles.each { |role| role_node(role) }
      end
    end
  end

  def role_node(role)
    div(
      class: "flex items-center gap-2 px-3 py-1 rounded-md " \
             "hover:bg-gray-100 dark:hover:bg-gray-800 group",
      data: { tree_target: "role", role_id: role.role_id, track: role.track }
    ) do
      input(
        type: "checkbox",
        class: "rounded-xs border-gray-300 dark:border-gray-600 text-primary " \
               "focus:ring-primary dark:bg-gray-700",
        checked: role_checked?(role),
        data: { action: "change->tree#toggleRole", role_id: role.role_id }
      )

      span(class: "text-sm text-gray-600 dark:text-gray-400 flex-1 truncate") { role.name }

      button(
        type: "button",
        class: "opacity-0 group-hover:opacity-100 px-1.5 py-0.5 text-xs rounded-sm " \
               "bg-gray-200 dark:bg-gray-700 text-gray-600 dark:text-gray-300 " \
               "hover:bg-primary/20 hover:text-primary transition-opacity",
        data: { action: "tree#solo", role_id: role.role_id },
        title: "Solo — focus on this role only"
      ) { "solo" }
    end
  end

  # ── Helpers ──

  def track_visible?(role)
    case @track_filter
    when "ic" then role.track == "ic"
    when "management" then role.track == "management"
    else true
    end
  end

  def role_checked?(role)
    if @selected_role_ids.empty?
      true
    else
      @selected_role_ids.include?(role.role_id)
    end
  end
end
