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
  # @param can_publish [Boolean] whether the current user can publish the draft — controls the Publish button
  # @param search_query [String, nil] active free-text matrix filter (echoed into the search box)
  def initialize(framework:, role_families:, selected_role_ids:, track_filter:,
                 matrix_data:, user: nil, current_tenant: nil, tenants: [], is_admin: false,
                 pending_suggestion_count: 0, mode: :view, can_edit: false, can_publish: false,
                 can_edit_structure: false, archive_survivors: [], roles: [],
                 current_person_id: nil, search_query: nil,
                 approval_authority: Frameworks::SuggestionApprovalAuthority.none,
                 edit_mode: :editing)
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
    @can_publish = can_publish
    @can_edit_structure = can_edit_structure
    @archive_survivors = archive_survivors
    @roles = roles
    @current_person_id = current_person_id
    @search_query = search_query
    @approval_authority = approval_authority
    @edit_mode = edit_mode
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(data: explorer_root_data) do
        framework_header
        explorer_layout
        structural_modals
        if @mode == :edit
          render Views::Frameworks::Explorer::FieldEditorTemplate.new
          reject_suggestion_modal
          resolve_clarification_modal
          request_clarification_modal
        end
      end
    end
  end

  # The reject-suggestion modal backing the actionable activity feed. Edit mode
  # only (where the feed lives); rendered for every edit-mode viewer — the
  # entry's Reject button is itself authority-gated, so an unauthorised viewer
  # simply never opens it. Shares the root `modal` controller (see
  # #explorer_root_data) with the structural modals.
  def reject_suggestion_modal
    render Views::Frameworks::Explorer::RejectSuggestionModal.new(
      framework_id: @framework.framework_id
    )
  end

  # Same placement rules as the reject modal — a pending clarification's
  # "Resolve…" (feed entry / pane card) opens it with a required note.
  def resolve_clarification_modal
    render Views::Frameworks::Explorer::ResolveClarificationModal.new(
      framework_id: @framework.framework_id
    )
  end

  # The other end of the clarification lifecycle — the grid's "Discuss…"
  # triggers (expectation cell, capability row kebab, illustration kebab) open
  # it to ask the question. Available to every edit-mode viewer: edit mode
  # already requires the suggest rights a clarification needs.
  def request_clarification_modal
    render Views::Frameworks::Explorer::RequestClarificationModal.new(
      framework_id: @framework.framework_id
    )
  end

  # The shared structural-edit modals (archive / add capability / add
  # category). All are opened by triggers in the matrix + header; the `modal`
  # controller (on the root, see #explorer_root_data) must be an ancestor of
  # both the triggers and these dialogs, and each trigger names its overlay via
  # `data-modal-target-id`.
  def structural_modals
    return unless structural_modals?

    render Views::Frameworks::Explorer::ArchiveModal.new(
      framework_id: @framework.framework_id, survivors: @archive_survivors
    )
    render Views::Frameworks::Explorer::AddCapabilityModal.new(
      framework_id: @framework.framework_id, roles: @roles
    )
    render Views::Frameworks::Explorer::AddCategoryModal.new(
      framework_id: @framework.framework_id
    )
    render Views::Frameworks::Explorer::ArchiveCategoryModal.new(
      framework_id: @framework.framework_id
    )
    render Views::Frameworks::Explorer::BindingEditorModal.new(
      framework_id: @framework.framework_id
    )
    render Views::Frameworks::Explorer::RoleFamilyEditModal.new(
      framework_id: @framework.framework_id, departments: role_family_departments
    )
    render Views::Frameworks::Explorer::RoleFamilyEditModal.new(
      framework_id: @framework.framework_id, departments: role_family_departments, mode: :new
    )
    render Views::Frameworks::Explorer::AddRoleModal.new(
      framework_id: @framework.framework_id
    )
    render Views::Frameworks::Explorer::AddRoleModal.new(
      framework_id: @framework.framework_id, mode: :edit
    )
    render Views::Frameworks::Explorer::LevelEditorModal.new(
      framework_id: @framework.framework_id
    )
    render Views::Frameworks::Explorer::AddLevelModal.new(
      framework_id: @framework.framework_id
    )
  end

  # Whether the shared structural-edit modals (+ the `modal` controller) render.
  def structural_modals? = @mode == :edit && @can_edit_structure

  # Distinct department labels across the framework's role families — feeds the
  # role-family edit dialog's <datalist> so contributors reuse existing groups.
  def role_family_departments
    @role_families.filter_map { |rf| rf.department.presence }.uniq.sort
  end

  # data-controller/action for the explorer root, adding the `modal`
  # controller + Esc-to-close in edit mode — it hosts both the structural
  # modals (when can_edit_structure) and the always-present reject-suggestion
  # modal (the actionable feed).
  def explorer_root_data
    controllers = [ "framework-explorer" ]
    actions = [ "tree:changed->framework-explorer#updateRoleCount" ]
    data = {}
    if @mode == :edit
      controllers << "modal"
      # ONE inline editor for the whole explorer — pencils delegate to it and it
      # clones the FieldEditorTemplate into place (#379).
      controllers << "field-editor"
      # ONE kebab-menu controller for the whole grid — triggers carry their items
      # as data and the menu is built on open (#380).
      controllers << "explorer-menu"
      actions << "keydown.esc@window->modal#escape"
      actions << "keydown.esc@window->explorer-menu#escape"
      actions << "keydown->explorer-menu#keydown"
      actions << "click@window->explorer-menu#clickOutside"
      actions << "suggestion:resolved@window->explorer-menu#onResolved"
      # A squiggle click opens a suggestion card — reveal the pane if collapsed.
      actions << "suggestion:open-card@window->framework-explorer#openContextPane"
      actions << "turbo:frame-render->field-editor#frameRendered"
      actions << "turbo:frame-missing->field-editor#frameMissing"
      actions << "turbo:fetch-request-error->field-editor#fetchError"
      actions << "framework-edit-mode:changed@window->field-editor#modeChanged"
      actions << "field-editor:discard@window->field-editor#discard"
      data[:field_editor_approvals_value] = editor_approvals.to_json
      data[:field_editor_mode_value] = @edit_mode.to_s
      data[:explorer_menu_paths_value] = menu_paths.to_json
    end
    data.merge(controller: controllers.join(" "), action: actions.join(" "))
  end

  # Route templates the grid's kebab menus build their actions from — once on
  # the root rather than on every trigger, and never hand-written in JS (#380).
  def menu_paths
    id = @framework.framework_id
    {
      approve: approve_framework_suggestion_path(id, ":id", inline: 1),
      capabilityReorder: framework_capability_reorders_path(framework_id: id),
      categoryReorder: framework_category_reorders_path(framework_id: id),
      illustrationArchive: framework_illustration_archives_path(framework_id: id)
    }
  end

  # Whether the viewer clears each content entity's review tier — computed
  # server-side (never guessed on the client) so the editor's Save vs Propose
  # label states what will actually happen. Combined client-side with the
  # Editing/Suggesting cookie, which the toggle can flip without a round trip.
  def editor_approvals
    Operations::Frameworks::SuggestEdit::EDITABLE_FIELDS.keys.index_with do |entity_type|
      @approval_authority.can_approve?(entity_type)
    end
  end

  private

  # ── Header ──

  def framework_header
    div(class: "mb-4") do
      div(class: "flex items-center justify-between") do
        div do
          a(href: frameworks_path,
            class: "text-sm text-gray-600 dark:text-gray-300 hover:text-primary mb-2 inline-block") do
            plain "\u2190 Frameworks"
          end
          div(class: "flex items-center gap-3") do
            h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { @framework.name }
            render Components::Kit::Badge.new(
              "v#{@framework.current_published_version}", variant: :info
            )
            draft_badge if @mode == :edit && @framework.draft?
            edit_mode_badge if @mode == :edit
          end
        end

        div(class: "flex items-center gap-2") do
          edit_suggest_toggle if @mode == :edit
          mode_switcher if @can_edit
          publish_button if @mode == :edit && @framework.draft? && @can_publish
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
    return locked_suggesting_badge unless @approval_authority.any?

    div(
      class: "inline-flex items-stretch rounded-md border border-gray-200 dark:border-gray-700 " \
             "bg-gray-50 dark:bg-gray-800 p-0.5 text-sm",
      data: {
        controller: "edit-mode-toggle",
        edit_mode_toggle_active_class: "bg-white dark:bg-gray-900 text-gray-900 dark:text-white shadow-xs",
        edit_mode_toggle_inactive_class: "text-gray-600 dark:text-gray-300 hover:text-gray-700 dark:hover:text-gray-200"
      }
    ) do
      edit_suggest_segment("editing", "Editing",
                           "Changes you make apply immediately (when you have approval authority).")
      edit_suggest_segment("suggesting", "Suggesting",
                           "Changes land as pending suggestions for review.")
    end
  end

  # A viewer who clears no review tier can never be "editing" — every change
  # they make lands as a suggestion — so the toggle is replaced by a static
  # label rather than offering a choice that does nothing.
  def locked_suggesting_badge
    span(
      class: "inline-flex items-center rounded-md border border-gray-200 dark:border-gray-700 " \
             "bg-gray-50 dark:bg-gray-800 px-3 py-1 text-sm font-medium " \
             "text-gray-600 dark:text-gray-300",
      title: "Your changes land as suggestions for a reviewer to approve."
    ) { "Suggesting" }
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

  # Draft status pill — edit mode only, only when an unpublished draft is
  # open. Teal to stay distinct from the blue published-version badge and
  # the amber edit-mode badge. Drafts are the normal working state (we roll
  # forward, always editing toward the next version), so this is an ambient
  # status, not a warning. Never rendered in view mode — viewers must not
  # learn a draft exists. Edit mode already requires FrameworkPolicy#edit?,
  # so gating on @mode == :edit is sufficient.
  def draft_badge
    render Components::Kit::Badge.new("v#{@framework.draft_version} draft", variant: :primary)
  end

  # Publish the current draft — owner/editor only, edit mode, draft open.
  # Sits to the right of "Exit edit mode". Links to the publish-review page
  # where the owner/editor validates the as-we-go migration mappings before
  # confirming — the review page is the deliberate confirmation step (no
  # inline dialog).
  def publish_button
    a(
      href: new_framework_publication_path(@framework.framework_id),
      class: "inline-flex items-center gap-1.5 rounded-sm px-3 py-1.5 text-sm font-semibold " \
             "bg-primary text-white hover:bg-primary/90 transition-colors",
      title: "Review and publish v#{@framework.draft_version}"
    ) { "Publish v#{@framework.draft_version}" }
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
      "text-gray-600 dark:text-gray-300 hover:text-gray-700 dark:hover:text-gray-200 " \
        "hover:bg-gray-100 dark:hover:bg-gray-800"
    end
  end

  def settings_link
    a(
      href: framework_settings_path(@framework.framework_id),
      class: "inline-flex items-center gap-1.5 rounded-sm px-3 py-1.5 text-sm " \
             "text-gray-600 dark:text-gray-300 hover:text-gray-700 dark:hover:text-gray-200 " \
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

    cap_count = @matrix_data[:in_scope_capability_count] ||
                @matrix_data[:categories].sum { |c| c[:capabilities].size }

    div(class: "mt-3 flex flex-wrap items-center gap-x-6 gap-y-2 text-sm text-gray-600 dark:text-gray-300") do
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
      add_category_button if structural_modals?
      search_box
      activity_toggle if @mode == :edit
    end
  end

  # "+ Add category" — opens the shared add-category modal. Edit mode +
  # edit-rights only (same bar as the row kebab).
  def add_category_button
    button(
      type: "button",
      class: "inline-flex items-center gap-1 px-2.5 py-1 rounded-md text-sm font-medium " \
             "text-primary hover:bg-primary/10 transition-colors",
      data: { action: "click->modal#open", modal_target_id: "add-category-modal" }
    ) do
      span(class: "text-base leading-none") { "+" }
      plain "Add category"
    end
  end

  # Free-text matrix filter. Composes with (does not replace) the role/track
  # selection — the matrix controller merges the query with the current role
  # scope from the browser URL. Lives in the header so it reads as a separate
  # axis from the role tree. Dispatches `framework-search:changed` (window);
  # `matrix#updateSearch` rebuilds the matrix Turbo Frame.
  def search_box
    div(
      class: "relative ml-auto w-64 max-sm:w-full",
      data: { controller: "framework-search" }
    ) do
      div(class: "pointer-events-none absolute inset-y-0 left-0 flex items-center pl-2.5") do
        svg(
          class: "w-4 h-4 text-gray-400", fill: "none", viewBox: "0 0 24 24",
          stroke: "currentColor", stroke_width: "2"
        ) do |s|
          s.path(stroke_linecap: "round", stroke_linejoin: "round",
                 d: "M21 21l-4.35-4.35M17 11a6 6 0 11-12 0 6 6 0 0112 0z")
        end
      end
      input(
        type: "search",
        value: @search_query,
        placeholder: "Filter capabilities…",
        autocomplete: "off",
        aria_label: "Filter capabilities by text",
        class: "w-full rounded-md border border-gray-200 dark:border-gray-700 " \
               "bg-white dark:bg-gray-800 py-1.5 pl-8 pr-8 text-sm " \
               "text-gray-900 dark:text-white placeholder:text-gray-400 " \
               "focus:border-primary focus:ring-1 focus:ring-primary focus:outline-hidden " \
               "[&::-webkit-search-cancel-button]:appearance-none",
        data: {
          framework_search_target: "input",
          action: "input->framework-search#onInput keydown->framework-search#onKeydown"
        }
      )
      button(
        type: "button",
        class: "absolute inset-y-0 right-0 flex items-center pr-2.5 text-gray-400 " \
               "hover:text-gray-600 dark:hover:text-gray-200 #{'hidden' if @search_query.blank?}",
        aria_label: "Clear filter",
        data: {
          framework_search_target: "clear",
          action: "framework-search#clear"
        }
      ) do
        svg(class: "w-4 h-4", fill: "none", viewBox: "0 0 24 24",
            stroke: "currentColor", stroke_width: "2") do |s|
          s.path(stroke_linecap: "round", stroke_linejoin: "round", d: "M6 18L18 6M6 6l12 12")
        end
      end
    end
  end

  # Rendered only in edit mode. View mode hides both the toggle and the
  # pane entirely — viewers have no business with the in-flight activity
  # feed, and the grid itself already suppresses pending-edit decorations
  # in view mode (see FrameworksController#load_explorer_matrix). The badge
  # surfaces the pending-suggestion count (the actionable subset) without
  # claiming to be the whole feed.
  def activity_toggle
    button(
      type: "button",
      class: "flex items-center gap-1.5 px-2.5 py-1 rounded-md " \
             "bg-gray-100 dark:bg-gray-800 " \
             "hover:bg-gray-200 dark:hover:bg-gray-700 transition-colors cursor-pointer",
      data: {
        action: "framework-explorer#toggleContextPane",
        framework_explorer_target: "contextPaneToggle"
      },
      title: "Toggle activity feed"
    ) do
      span(class: "font-semibold text-gray-900 dark:text-white") { "Activity" }
      if @pending_suggestion_count.positive?
        span(class: "inline-flex items-center rounded-full bg-amber-100 dark:bg-amber-900/40 " \
                    "px-1.5 py-0.5 text-[11px] font-medium text-amber-800 dark:text-amber-200") do
          "#{@pending_suggestion_count} pending"
        end
      end
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
        matrix_base_path_value: matrix_base_path,
        action: "tree:changed->matrix#updateSelection " \
                "framework-search:changed@window->matrix#updateSearch " \
                "suggestion:navigate@window->matrix#navigateToEntity " \
                "suggestion:resolved@window->matrix#refresh " \
                "org-structure:updated@window->matrix#refresh"
      }
    ) do
      left_pane
      main_pane
      right_pane_placeholder if @mode == :edit
    end
  end

  # Matrix Turbo Frame endpoint the role/text filters re-fetch from. Must
  # match the current mode — filtering in edit mode has to keep hitting the
  # edit matrix, otherwise a filter (or clearing one) silently drops the
  # explorer back to published/view state.
  def matrix_base_path
    if @mode == :edit
      edit_matrix_framework_path(@framework.framework_id)
    else
      matrix_framework_path(@framework.framework_id)
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
        track_filter: @track_filter,
        framework_id: @framework.framework_id,
        mode: @mode,
        can_edit_structure: @can_edit_structure
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
          current_person_id: @current_person_id,
          can_edit_structure: @can_edit_structure,
          approval_authority: @approval_authority
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
        context_pane_base_path_value: framework_activity_path(@framework.framework_id),
        context_pane_initial_role_ids_value: @selected_role_ids.to_json,
        context_pane_initial_track_value: @track_filter,
        action: "tree:changed@window->context-pane#onTreeChanged " \
                "matrix:focus-changed@window->context-pane#onFocusChanged " \
                "suggestion:submitted@window->context-pane#onSuggestionSubmitted " \
                "suggestion:open-card@window->context-pane#onOpenSuggestionCard "
      }
    ) do
      # Live sync: any framework activity event broadcasts a replace of the
      # signal element below; the context-pane controller observes it and
      # reloads the feed frame for every edit-mode viewer (incl. the actor).
      turbo_stream_from "framework_activity", @framework.framework_id
      div(id: "framework-activity-sync-signal", class: "hidden",
          data: { context_pane_target: "signal" })

      # No `src:` — the context-pane Stimulus controller sets the src on
      # connect with any focus/role params applied. Avoids a race where the
      # auto-fetch with an unfocused URL lands before the controller primes
      # the focused URL on a deep link.
      turbo_frame_tag(
        "suggestion-panel",
        class: "block h-full",
        data: { context_pane_target: "frame" }
      ) do
        div(class: "p-6 text-center text-gray-600 dark:text-gray-300 text-sm") do
          p { "Loading activity\u2026" }
        end
      end
    end
  end
end
