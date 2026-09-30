# frozen_string_literal: true

# Framework-specific role tree for the explorer left pane.
#
# Three-level hierarchy: Department → Role Family → Role.
# If role families have no department set, they appear ungrouped at the top.
#
# Visibility per mode: view mode hides **ghost** roles (no published levels)
# and families with nothing visible — the published view stays clean; edit
# mode shows everything, with ghosts wiggled (see GhostEntities).
#
class Views::Frameworks::Explorer::RoleTree < Views::Base
  include Phlex::Rails::Helpers::TurboFrameTag
  include Views::Frameworks::Explorer::Concerns::GhostEntities
  # For the shared kebab_trigger + kebab_item_classes (the tree passes its
  # denser padding).
  include Views::Frameworks::Explorer::Concerns::KebabChrome
  include Views::Frameworks::Explorer::Concerns::HoverCluster
  # The rename pencils are rendered by the ROW (into its floating action
  # cluster), not by the name frames, so the tree needs the pencil helper —
  # and the concern's own comment predicted this exact NoMethodError.
  include Views::Frameworks::Explorer::Concerns::InlineEditable

  TRACK_OPTIONS = [
    { value: "both", label: "All" },
    { value: "ic", label: "IC" },
    { value: "management", label: "Mgmt" }
  ].freeze

  # @param role_families [Array<FrameworkState::RoleFamily>] eager-loaded with roles
  # @param selected_role_ids [Array<String>] currently selected role UUIDs
  # @param track_filter [String] "ic", "management", or "both"
  # @param framework_id [String, nil] required in :edit mode for inline-edit form actions
  # @param mode [Symbol] :view or :edit — gates the inline rename pencils
  # @param can_edit_structure [Boolean] gates the per-family "Edit" dialog trigger
  #   (the update_role_family? bar) — keeps it off for suggest-only viewers
  def initialize(role_families:, selected_role_ids:, track_filter:, framework_id: nil, mode: :view,
                 can_edit_structure: false)
    @role_families = role_families
    @selected_role_ids = selected_role_ids
    @track_filter = track_filter
    @framework_id = framework_id
    @mode = mode
    @can_edit_structure = can_edit_structure
  end

  def view_template
    div(class: "flex flex-col h-full") do
      header_section
      solo_hint
      div(class: "flex-1 overflow-y-auto p-3") do
        # The grouped families live in their own Turbo Frame so a role-family
        # edit (which can change the department grouping) re-renders just this
        # list — moving the family under a new header — while the surrounding
        # `tree` controller, track filter, and header stay put. See
        # Frameworks::RoleFamiliesController#update.
        turbo_frame_tag("role-tree-families") do
          nav(class: "space-y-1", role: "tree") do
            departments_with_families.each do |dept_name, families|
              department_group(dept_name, families)
            end
          end
          add_role_family_row if @mode == :edit && @can_edit_structure
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
            class: "text-xs text-primary-ink hover:underline",
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
        span(class: "font-semibold text-primary-ink") { "Solo" }
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
      .select { |rf| family_visible?(rf) }
      .group_by { |rf| rf.respond_to?(:department) ? rf.department : nil }

    # Sort: named departments first (alphabetically), then ungrouped
    grouped.sort_by { |dept, _| dept || "zzz" }
  end

  def department_group(dept_name, families)
    if dept_name.present?
      # Department header (inline-renameable in edit mode) + collapsible content.
      # Renaming the header relabels every family in the group at once.
      div(class: "mb-2") do
        render Views::Frameworks::Explorer::DepartmentNameFrame.new(
          department: dept_name, framework_id: @framework_id,
          mode: (@mode == :edit && @can_edit_structure) ? :edit : :view
        )
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
    visible_roles = role_family.roles.select { |r| role_visible?(r) }.sort_by(&:name)
    return if visible_roles.empty? && @mode != :edit

    all_checked = visible_roles.any? && visible_roles.all? { |r| role_checked?(r) }
    some_checked = visible_roles.any? { |r| role_checked?(r) }

    div(
      class: "select-none",
      data: { tree_target: "group", family_id: role_family.role_family_id }
    ) do
      # Family header
      # The row owns its hover cluster: the family's inline-rename pencil reveals
      # with the row's other hover controls, not on the name span (§11a).
      div(class: "flex items-center gap-2 px-3 py-1.5 rounded-md " \
                 "hover:bg-gray-100 dark:hover:bg-gray-800 cursor-pointer group",
          data: hover_cluster_data("tree")) do
        # Disclosure triangle
        button(
          type: "button",
          class: "w-4 h-4 flex items-center justify-center text-gray-400 " \
                 "hover:text-gray-600 dark:hover:text-gray-300 transition-transform",
          data: { action: "tree#toggleGroup", family_id: role_family.role_family_id },
          aria: { expanded: true }
        ) do
          icon("chevron-right", class: "w-3 h-3 rotate-90 transition-transform")
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

        # The name owns the row's spare width; its hover controls float over the
        # right edge of THIS box rather than sitting in the row's flow, so they
        # reserve nothing (§11a's own trap — `opacity-0` still takes layout
        # width). The count stays inline and always visible, to the right of the
        # cluster's box, so it is never masked.
        name_slot do
          render Views::Frameworks::Explorer::RoleFamilyNameFrame.new(
            role_family: role_family, framework_id: @framework_id, mode: @mode
          )
          if @mode == :edit
            div(class: "tree-actions") do
              render_inline_editor_pencil(
                aria_label: "Edit role family name", scope: "tree", collapses: false,
                host_frame: "role-family-name-#{role_family.role_family_id}"
              )
              family_edit_trigger(role_family) if @can_edit_structure
            end
          end
        end

        span(class: "shrink-0 text-xs text-gray-600 dark:text-gray-300") { visible_roles.size.to_s }
      end

      # Roles
      div(
        class: "ml-6 space-y-0.5",
        data: { tree_target: "childList", family_id: role_family.role_family_id }
      ) do
        visible_roles.each { |role| role_node(role) }
        # Only reachable in edit mode (the empty-family guard above) — a ghost
        # family renders its emptiness explicitly rather than a bare header.
        if visible_roles.empty?
          div(class: "px-3 py-1 text-xs italic text-gray-400 dark:text-gray-500") { "No roles yet" }
        end
        add_role_row(role_family) if @mode == :edit && @can_edit_structure
      end
    end
  end

  # "+ Add role" row at the foot of a family's role list — opens the shared
  # add-role modal, naming this family via the trigger dataset (the parent is
  # implied by placement, so the modal needs no family picker). Mirrors the
  # matrix's "+ Add capability" affordance one pane over.
  def add_role_row(role_family)
    div(class: "px-3 py-1") do
      button(
        type: "button",
        class: "inline-flex items-center gap-1 text-xs font-medium text-primary-ink hover:underline",
        data: {
          action: "click->modal#open",
          modal_target_id: "add-role-modal",
          add_role_family_id: role_family.role_family_id,
          add_role_family_name: role_family.name
        }
      ) do
        span(class: "text-sm leading-none") { "+" }
        plain "Add role"
      end
    end
  end

  # "+ Add role family" at the foot of the tree — opens the shared new-family
  # modal (the RoleFamilyEditModal in :new mode). Inside the families frame so
  # it survives frame re-renders.
  def add_role_family_row
    div(class: "px-3 pt-2 mt-1 border-t border-gray-100 dark:border-gray-800") do
      button(
        type: "button",
        class: "inline-flex items-center gap-1 text-xs font-medium text-primary-ink hover:underline",
        data: {
          action: "click->modal#open",
          modal_target_id: "role-family-new-modal",
          role_family_new: "1"
        }
      ) do
        span(class: "text-sm leading-none") { "+" }
        plain "Add role family"
      end
    end
  end

  # Hover-revealed "edit role family" trigger — opens the shared role-family
  # edit dialog (name + description + department) via the root `modal`
  # controller, prefilled from these data attributes. Moving the family between
  # departments is just editing its `department` string. Sits alongside the
  # inline name pencil (which stays for quick renames).
  def family_edit_trigger(role_family)
    button(
      type: "button",
      class: "opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 " \
             "focus-visible:opacity-100 shrink-0 p-0.5 rounded-sm " \
             "text-gray-400 hover:text-primary-ink transition-opacity",
      data: {
        action: "click->modal#open",
        modal_target_id: "role-family-edit-modal",
        role_family_edit_id: role_family.role_family_id,
        role_family_edit_name: role_family.name,
        role_family_edit_description: role_family.description,
        role_family_edit_department: role_family.department
      },
      title: "Edit role family",
      aria: { label: "Edit #{role_family.name}" }
    ) do
      icon("pencil", class: "w-3.5 h-3.5")
    end
  end

  def role_node(role)
    div(
      class: "flex items-center gap-2 px-3 py-1 rounded-md " \
             "hover:bg-gray-100 dark:hover:bg-gray-800 group",
      data: hover_cluster_data("tree")
              .merge(tree_target: "role", role_id: role.role_id, track: role.track)
    ) do
      input(
        type: "checkbox",
        class: "rounded-xs border-gray-300 dark:border-gray-600 text-primary " \
               "focus:ring-primary dark:bg-gray-700",
        checked: role_checked?(role),
        data: { action: "change->tree#toggleRole", role_id: role.role_id }
      )

      # Same arrangement as the family row: the name takes the width, its
      # controls float over the right edge and reserve none of it. In edit mode
      # the reserved cluster (solo pill + pencil + ⋮) was ~90 px of a ~190 px
      # slot, which is what wrapped almost every real role name onto two lines.
      name_slot do
        render Views::Frameworks::Explorer::RoleNameFrame.new(
          role: role, framework_id: @framework_id, mode: @mode
        )

        div(class: "tree-actions") do
          if @mode == :edit
            render_inline_editor_pencil(
              aria_label: "Edit role name", scope: "tree", collapses: false,
              host_frame: "role-name-#{role.role_id}"
            )
          end

          button(
            type: "button",
            # Focus reveals it too, or a keyboard user tabs to a transparent
            # button that still fires `tree#solo` — the same pair
            # `family_edit_trigger` carries.
            class: "opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 " \
                   "focus-visible:opacity-100 shrink-0 px-1.5 py-0.5 text-xs rounded-sm " \
                   "bg-gray-200 dark:bg-gray-700 text-gray-600 dark:text-gray-300 " \
                   "hover:bg-primary/20 hover:text-primary-ink transition-opacity",
            data: { action: "tree#solo", role_id: role.role_id },
            title: "Solo — focus on this role only"
          ) { "solo" }

          role_actions_kebab(role) if @mode == :edit && @can_edit_structure
        end
      end
    end
  end

  # The row's name area: a positioning context the name fills and the row's
  # hover controls float over. Everything after it in the row (a family's role
  # count) stays inline and unmasked.
  def name_slot(&block)
    div(class: "relative flex-1 min-w-0 flex items-center", &block)
  end

  # Role-row actions kebab (⋮) — the scalable home for the role's actions, so
  # the hover row doesn't accumulate one button per action (the MatrixRow
  # kebab precedent). "Add level…" lives here too: as a standalone "+ level"
  # button it permanently reserved row width (opacity-0 still takes layout
  # space) and crushed role names down to a few characters.
  def role_actions_kebab(role)
    # :fixed — the tree pane is an overflow container (aside overflow-hidden +
    # the scroll list), which clips an absolutely-positioned menu at its edge.
    render Components::Kit::Dropdown.new(align: :left, strategy: :fixed) do |dd|
      kebab_trigger(dd, label: "Role actions",
        reveal_classes: "opacity-0 group-hover:opacity-100 group-focus-within:opacity-100")
      dd.menu do
        button(
          type: "button", role: "menuitem", class: kebab_item_classes(padding: "px-3 py-1.5"),
          data: {
            action: "click->modal#open",
            modal_target_id: "add-level-modal",
            add_level_role_id: role.role_id,
            add_level_role_name: role.name,
            add_level_next_ordinal: next_ordinal_for(role),
            # Draft levels included (graph-sourced) — feeds the modal's instant
            # duplicate-ordinal validation.
            add_level_taken_ordinals: role.levels.map(&:ordinal).sort.join(",")
          }
        ) { "Add level…" }
        button(
          type: "button", role: "menuitem", class: kebab_item_classes(padding: "px-3 py-1.5"),
          data: {
            action: "click->modal#open",
            modal_target_id: "role-edit-modal",
            role_edit_id: role.role_id,
            role_edit_name: role.name,
            role_edit_code: role.code,
            role_edit_track: role.track
          }
        ) { "Edit role…" }
        button(
          type: "button", role: "menuitem", class: kebab_item_classes(padding: "px-3 py-1.5"),
          data: {
            action: "click->modal#open",
            modal_target_id: "level-editor-modal",
            level_editor_role_id: role.role_id
          }
        ) { "Edit levels…" }
      end
    end
  end

  # Next free ordinal for the role — max across ALL its levels (draft-added
  # included; the graph carries them) so the prefill never collides.
  def next_ordinal_for(role)
    (role.levels.map(&:ordinal).max || 0) + 1
  end

  # ── Helpers ──

  # View mode shows only what the published framework view contains: ghost
  # roles (no published levels — freshly added live, or levels still in draft)
  # are hidden, and a family with nothing visible is hidden with them. Edit
  # mode shows everything — ghosts render with the wiggle (GhostEntities), and
  # an empty family stays visible so it can be populated (the empty-category
  # rule, Hard-Won Lesson 18, one pane left).
  def family_visible?(role_family)
    return true if @mode == :edit && role_family.roles.empty?

    role_family.roles.any? { |r| role_visible?(r) }
  end

  def role_visible?(role)
    track_visible?(role) && (@mode == :edit || published_role?(role))
  end

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
