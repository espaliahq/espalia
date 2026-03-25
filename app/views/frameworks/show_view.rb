# frozen_string_literal: true

# Three-pane Framework Explorer.
#
# Left pane: role tree with solo mode and track filters.
# Main pane: capability × level matrix (Turbo Frame, server-rendered).
# Right pane: placeholder for future contextual feed.
#
class Views::Frameworks::ShowView < Views::Base
  # @param framework [FrameworkState::Framework]
  # @param role_families [Array<FrameworkState::RoleFamily>] eager-loaded with roles + levels
  # @param selected_role_ids [Array<String>]
  # @param track_filter [String]
  # @param matrix_data [Hash] output from MatrixDataBuilder
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  # @param is_admin [Boolean] whether to show admin controls (settings link)
  def initialize(framework:, role_families:, selected_role_ids:, track_filter:,
                 matrix_data:, user: nil, current_tenant: nil, tenants: [], is_admin: false)
    @framework = framework
    @role_families = role_families
    @selected_role_ids = selected_role_ids
    @track_filter = track_filter
    @matrix_data = matrix_data
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
    @is_admin = is_admin
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
          end
        end

        settings_link if @is_admin
      end

      stats_bar
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
        action: "tree:changed->matrix#updateSelection"
      }
    ) do
      left_pane
      main_pane
      right_pane_placeholder
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
          framework_id: @framework.framework_id
        )
      end
    end
  end

  def right_pane_placeholder
    aside(
      class: "w-80 shrink-0 border-l border-gray-200 dark:border-gray-700 " \
             "bg-white dark:bg-gray-900 hidden",
      data: { framework_explorer_target: "contextPane" }
    ) do
      div(class: "p-6 text-center text-gray-400 dark:text-gray-500 text-sm") do
        p { "Context pane coming soon" }
      end
    end
  end
end
