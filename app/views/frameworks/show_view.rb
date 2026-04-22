# frozen_string_literal: true

# Three-pane Framework Explorer.
#
# Left pane: role tree with solo mode and track filters.
# Main pane: capability × level matrix (Turbo Frame, server-rendered).
# Right pane: placeholder for future contextual feed.
#
class Views::Frameworks::ShowView < Views::Base
  # @param framework [FrameworkState::Framework, Frameworks::ExplorerGraph::Framework]
  # @param role_families [Array] role families with roles + levels
  # @param selected_role_ids [Array<String>]
  # @param track_filter [String]
  # @param matrix_data [Hash] output from MatrixDataBuilder
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  # @param is_admin [Boolean] whether to show admin controls (settings link)
  # @param pending_suggestion_count [Integer] count for the suggestions toggle badge
  # @param mode [Symbol] :view (default) or :edit — gates inline-edit affordances and sets context-pane default-open
  # @param can_edit [Boolean] whether the current user can reach edit mode — controls mode switcher visibility
  def initialize(framework:, role_families:, selected_role_ids:, track_filter:,
                 matrix_data:, user: nil, current_tenant: nil, tenants: [], is_admin: false,
                 pending_suggestion_count: 0, mode: :view, can_edit: false,
                 current_person_id: nil)
    @framework = framework
    @role_families = role_families
    @selected_role_ids = selected_role_ids
    @track_filter = track_filter
    @matrix_data = matrix_data
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
    @is_admin = is_admin
    @pending_suggestion_count = pending_suggestion_count
    @mode = mode
    @can_edit = can_edit
    @current_person_id = current_person_id
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(data: {
        controller: "framework-explorer",
        action: "tree:changed->framework-explorer#updateRoleCount"
      }) do
        framework_header
        explorer_layout
      end
    end
  end

  private

  # ── Header ──

  def framework_header
    div(class: "mb-4") do
      div(class: "flex items-center justify-between") do
        div do
          a(href: frameworks_path,
            class: "text-sm text-gray-500 dark:text-gray-400 hover:text-primary mb-2 inline-block") do
            plain "\u2190 Frameworks"
          end
          div(class: "flex items-center gap-3") do
            h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { @framework.name }
            render Components::Kit::Badge.new(
              "v#{@framework.current_published_version}", variant: :info
            )
            edit_mode_badge if @mode == :edit
          end
        end

        div(class: "flex items-center gap-2") do
          edit_suggest_toggle if @mode == :edit
          mode_switcher if @can_edit
          settings_link if @is_admin
        end
      end

      stats_bar
    end
  end

  # Segmented Editing / Suggesting toggle — only rendered in edit mode.
  # Persisted client-side via the `framework_edit_mode` cookie; read
  # server-side by the FrameworkEditMode concern on every inline-edit
  # submission.
  def edit_suggest_toggle
    div(
      class: "inline-flex items-stretch rounded-md border border-gray-200 dark:border-gray-700 " \
             "bg-gray-50 dark:bg-gray-800 p-0.5 text-sm",
      data: {
        controller: "edit-mode-toggle",
        edit_mode_toggle_active_class: "bg-white dark:bg-gray-900 text-gray-900 dark:text-white shadow-xs",
        edit_mode_toggle_inactive_class: "text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-200"
      }
    ) do
      edit_suggest_segment("editing", "Editing",
                           "Changes you make apply immediately (when you have approval authority).")
      edit_suggest_segment("suggesting", "Suggesting",
                           "Changes land as pending suggestions for review.")
    end
  end

  def edit_suggest_segment(value, label, tooltip)
    button(
      type: "button",
      class: "inline-flex items-center rounded px-3 py-1 font-medium transition-colors",
      data: {
        action: "edit-mode-toggle#select",
        edit_mode_toggle_target: "#{value}Button",
        edit_mode_value: value
      },
      title: tooltip,
      aria_pressed: "false"
    ) { label }
  end

  # Shown only while rendering /edit to make the mode visible even when
  # the toggle isn't (e.g. mobile-narrow viewports). Amber to stand out
  # from the blue version badge.
  def edit_mode_badge
    render Components::Kit::Badge.new("Edit mode", variant: :warning)
  end

  # Mode switcher pill — always rendered when the user can reach edit mode,
  # so there is a clear exit from edit back to view. Hidden for pure viewers
  # (the edit route is 404 for them anyway).
  def mode_switcher
    target_path = @mode == :edit ? framework_path(@framework.framework_id) : edit_framework_path(@framework.framework_id)
    target_label = @mode == :edit ? "Exit edit mode" : "Edit mode"

    a(
      href: target_path,
      class: "inline-flex items-center gap-1.5 rounded-sm px-3 py-1.5 text-sm " \
             "#{mode_switcher_style_classes} " \
             "transition-colors",
      title: target_label
    ) do
      svg(
        xmlns: "http://www.w3.org/2000/svg", fill: "none", viewbox: "0 0 24 24",
        stroke_width: "1.5", stroke: "currentColor", class: "w-4 h-4"
      ) do |s|
        s.path(
          stroke_linecap: "round", stroke_linejoin: "round",
          d: "M16.862 4.487l1.687-1.688a1.875 1.875 0 112.652 2.652L6.832 " \
             "19.82a4.5 4.5 0 01-1.897 1.13l-2.685.8.8-2.685a4.5 4.5 0 " \
             "011.13-1.897L16.863 4.487zm0 0L19.5 7.125"
        )
      end
      plain target_label
    end
  end

  def mode_switcher_style_classes
    if @mode == :edit
      "bg-amber-100 text-amber-800 hover:bg-amber-200 " \
        "dark:bg-amber-900/40 dark:text-amber-200 dark:hover:bg-amber-900/60"
    else
      "text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-200 " \
        "hover:bg-gray-100 dark:hover:bg-gray-800"
    end
  end

  def settings_link
    a(
      href: framework_settings_path(@framework.framework_id),
      class: "inline-flex items-center gap-1.5 rounded-sm px-3 py-1.5 text-sm " \
             "text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-200 " \
             "hover:bg-gray-100 dark:hover:bg-gray-800 transition-colors",
      title: "Framework settings"
    ) do
      svg(
        xmlns: "http://www.w3.org/2000/svg", fill: "none", viewbox: "0 0 24 24",
        stroke_width: "1.5", stroke: "currentColor", class: "w-4 h-4"
      ) do |s|
        s.path(
          stroke_linecap: "round", stroke_linejoin: "round",
          d: "M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.325.196.72.257 1.075.124l1.217-.456a1.125 1.125 0 0 1 1.37.49l1.296 2.247a1.125 1.125 0 0 1-.26 1.431l-1.003.827c-.293.241-.438.613-.43.992a7.723 7.723 0 0 1 0 .255c-.008.378.137.75.43.991l1.004.827c.424.35.534.955.26 1.43l-1.298 2.247a1.125 1.125 0 0 1-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.47 6.47 0 0 1-.22.128c-.331.183-.581.495-.644.869l-.213 1.281c-.09.543-.56.94-1.11.94h-2.594c-.55 0-1.019-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 0 1-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 0 1-1.369-.49l-1.297-2.247a1.125 1.125 0 0 1 .26-1.431l1.004-.827c.292-.24.437-.613.43-.991a6.932 6.932 0 0 1 0-.255c.007-.38-.138-.751-.43-.992l-1.004-.827a1.125 1.125 0 0 1-.26-1.43l1.297-2.247a1.125 1.125 0 0 1 1.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.086.22-.128.332-.183.582-.495.644-.869l.214-1.28Z"
        )
        s.path(
          stroke_linecap: "round", stroke_linejoin: "round",
          d: "M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"
        )
      end
      plain "Settings"
    end
  end

  def stats_bar
    role_count = @matrix_data[:selected_roles].size
    level_count = @matrix_data[:merged_levels].size
    cap_count = @matrix_data[:categories].sum { |c| c[:capabilities].size }

    div(class: "mt-3 flex items-center gap-6 text-sm text-gray-500 dark:text-gray-400") do
      # Roles stat doubles as the toggle button for the role pane
      button(
        type: "button",
        class: "flex items-center gap-1.5 px-2.5 py-1 -ml-2.5 rounded-md " \
               "bg-gray-100 dark:bg-gray-800 " \
               "hover:bg-gray-200 dark:hover:bg-gray-700 transition-colors cursor-pointer",
        data: {
          action: "framework-explorer#toggleRolePane",
          framework_explorer_target: "rolePaneToggle"
        }
      ) do
        # Toggle chevron — rotates when pane is open/closed
        svg(
          class: "w-3.5 h-3.5 text-gray-400 transition-transform",
          data: { framework_explorer_target: "toggleChevron" },
          fill: "none", viewBox: "0 0 24 24", stroke: "currentColor", stroke_width: "2"
        ) do |s|
          s.path(d: "M19 9l-7 7-7-7")
        end
        span(class: "font-semibold text-gray-900 dark:text-white",
             data: { framework_explorer_target: "roleCount" }) { role_count.to_s }
        span(data: { framework_explorer_target: "roleLabel" }) do
          " #{'Role'.pluralize(role_count)}"
        end
      end
      stat_item("Levels", level_count)
      stat_item("Capabilities", cap_count)
      suggestions_toggle if @mode == :edit
    end
  end

  # Rendered only in edit mode. View mode hides both the toggle and the
  # pane entirely — viewers have no business with the in-flight
  # suggestion feed, and the grid itself already suppresses pending-edit
  # decorations in view mode (see FrameworksController#load_explorer_matrix).
  def suggestions_toggle
    button(
      type: "button",
      class: "ml-auto flex items-center gap-1.5 px-2.5 py-1 rounded-md " \
             "bg-gray-100 dark:bg-gray-800 " \
             "hover:bg-gray-200 dark:hover:bg-gray-700 transition-colors cursor-pointer",
      data: {
        action: "framework-explorer#toggleContextPane",
        framework_explorer_target: "contextPaneToggle"
      },
      title: "Toggle suggestions panel"
    ) do
      span(class: "font-semibold text-gray-900 dark:text-white") do
        @pending_suggestion_count.to_s
      end
      span { " #{'Suggestion'.pluralize(@pending_suggestion_count)}" }
    end
  end

  def stat_item(label, count)
    span do
      span(class: "font-semibold text-gray-900 dark:text-white") { count.to_s }
      plain " #{label}"
    end
  end

  # ── Explorer Layout ──

  def explorer_layout
    div(
      class: "flex -mx-6 -mb-6 h-[calc(100vh-12rem)] border-t border-gray-200 dark:border-gray-700",
      data: {
        controller: "matrix",
        matrix_base_path_value: matrix_framework_path(@framework.framework_id),
        action: "tree:changed->matrix#updateSelection " \
                "suggestion:navigate@window->matrix#navigateToEntity"
      }
    ) do
      left_pane
      main_pane
      right_pane_placeholder if @mode == :edit
    end
  end

  def left_pane
    aside(
      class: "w-72 shrink-0 border-r border-gray-200 dark:border-gray-700 " \
             "bg-white dark:bg-gray-900 flex flex-col overflow-hidden " \
             "max-lg:hidden",
      data: {
        controller: "tree",
        framework_explorer_target: "rolePane"
      }
    ) do
      render Views::Frameworks::Explorer::RoleTree.new(
        role_families: @role_families,
        selected_role_ids: @selected_role_ids,
        track_filter: @track_filter
      )
    end
  end

  def main_pane
    div(
      class: "flex-1 overflow-auto bg-white dark:bg-gray-900",
      data: { matrix_target: "scrollContainer" }
    ) do
      turbo_frame_tag("framework-matrix", data: { matrix_target: "frame" }) do
        render Views::Frameworks::Explorer::Matrix.new(
          matrix_data: @matrix_data,
          selected_role_ids: @selected_role_ids,
          framework_id: @framework.framework_id,
          mode: @mode,
          current_person_id: @current_person_id
        )
      end
    end
  end

  def right_pane_placeholder
    # Edit mode only — view mode omits the pane entirely
    # (FrameworksController hides pending-suggestion indicators from the
    # grid too, so viewers see only published state).
    aside(
      class: "w-80 shrink-0 border-l border-gray-200 dark:border-gray-700 " \
             "bg-white dark:bg-gray-900 flex flex-col overflow-hidden",
      data: {
        framework_explorer_target: "contextPane",
        controller: "context-pane",
        context_pane_base_path_value: framework_suggestions_path(@framework.framework_id),
        context_pane_initial_role_ids_value: @selected_role_ids.to_json,
        context_pane_initial_track_value: @track_filter,
        action: "tree:changed@window->context-pane#onTreeChanged " \
                "matrix:focus-changed@window->context-pane#onFocusChanged " \
                "suggestion:submitted@window->context-pane#onSuggestionSubmitted"
      }
    ) do
      # No `src:` — the context-pane Stimulus controller sets the src on
      # connect with any focus/role params applied. Avoids a race where the
      # auto-fetch with an unfocused URL lands before the controller primes
      # the focused URL on a deep link.
      turbo_frame_tag(
        "suggestion-panel",
        class: "block h-full",
        data: { context_pane_target: "frame" }
      ) do
        div(class: "p-6 text-center text-gray-400 dark:text-gray-500 text-sm") do
          p { "Loading suggestions\u2026" }
        end
      end
    end
  end
end
