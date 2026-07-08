# frozen_string_literal: true

# The unified evidence form, rendered into the `#evidence-modal` turbo-frame by
# EvidenceModalController. One component for new / edit / respond, across the
# assessment screen and the hub. Single source of TYPE_OPTIONS / SYSTEM_OPTIONS.
#
# Submits the FULL desired state (content + the complete set of linked cells +
# optional request_id); the server diffs and emits the minimal commands.
class Views::Evidence::ModalForm < Views::Base
  include Phlex::Rails::Helpers::FormWith

  TYPE_OPTIONS = [
    [ "Peer feedback", "peer_feedback" ], [ "Manager feedback", "manager_feedback" ],
    [ "Customer feedback", "customer_feedback" ], [ "Impact", "impact" ],
    [ "Project outcome", "project_outcome" ], [ "Code review", "code_review" ],
    [ "Design review", "design_review" ], [ "Incident response", "incident_response" ],
    [ "Presentation", "presentation" ], [ "Mentoring", "mentoring" ],
    [ "Observation", "observation" ], [ "Other (describe)", "other" ]
  ].freeze

  SYSTEM_OPTIONS = [
    [ "(none)", "" ], [ "GitHub", "github" ], [ "GitLab", "gitlab" ], [ "Linear", "linear" ],
    [ "Jira", "jira" ], [ "Slack", "slack" ], [ "Notion", "notion" ], [ "Google Doc", "google_doc" ],
    [ "Figma", "figma" ], [ "Other", "other" ]
  ].freeze

  INPUT = "w-full rounded-md border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 " \
          "text-gray-900 dark:text-gray-100 text-sm " \
          "focus-visible:ring-primary focus-visible:border-primary disabled:opacity-60 disabled:cursor-not-allowed"
  LABEL = "block text-xs font-medium text-gray-700 dark:text-gray-200 mb-1"
  SECONDARY_BTN = "inline-flex items-center min-h-11 px-3 rounded-md border border-gray-300 dark:border-gray-600 " \
                  "text-sm font-medium text-gray-700 dark:text-gray-200 cursor-pointer"

  def initialize(mode:, assignment_id:, primary_cell:, content_editable:, context_block:,
                 link_options: [], level_options: [], linked_cells: [], expectation_map: {},
                 evidence: nil, request: nil, return_to: nil)
    @mode = mode.to_sym
    @assignment_id = assignment_id
    @primary_cell = primary_cell
    @content_editable = content_editable
    @context_block = context_block
    @link_options = link_options
    @level_options = level_options
    @linked_cells = linked_cells
    @expectation_map = expectation_map
    @evidence = evidence
    @request = request
    @return_to = return_to
  end

  def view_template
    turbo_frame_tag("evidence-modal") do
      div(class: "p-5", data: { controller: "evidence-modal" }) do
        header
        context_card
        # _top so the submit isn't captured by the #evidence-modal frame: the
        # hub's redirect must navigate the page, and turbo_stream responses (the
        # assessment surface) still apply globally regardless of frame target.
        form_with(url: form_action, method: form_method, class: "space-y-3",
                  data: { turbo_frame: "_top", action: "turbo:submit-end->modal#submitted" }) do
          hidden_fields
          content_fields
          links_section
          expectation_data
          level_data
          footer
        end
      end
    end
  end

  private

  def header
    div(class: "flex items-center justify-between mb-3") do
      h2(class: "text-base font-semibold text-gray-900 dark:text-white") { title }
      button(type: "button", aria: { label: "Close" }, data: { action: "modal#close" },
             class: "h-9 w-9 inline-flex items-center justify-center rounded-md text-gray-500 hover:text-gray-800 dark:hover:text-gray-200") { "×" }
    end
  end

  def title
    { new: "Add feedback / evidence", edit: "Edit feedback / evidence", respond: "Provide feedback / evidence" }.fetch(@mode)
  end

  # Primary-cell context: capability · level, the behavioural expectation, and
  # (primary only) the role illustrations. Role/level chrome only off the hub.
  def context_card
    cx = @context_block
    div(class: "rounded-md bg-gray-50 dark:bg-gray-800/60 border border-gray-100 dark:border-gray-700 p-3 space-y-2 mb-4") do
      div do
        p(class: "text-sm font-medium text-gray-900 dark:text-white") { primary_label(cx) }
        p(class: "text-xs text-gray-600 dark:text-gray-300") { scope_label(cx) } if cx[:show_role_level]
      end
      if cx[:expectation].present?
        div do
          span(class: "block text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") { "What good looks like" }
          p(class: "mt-0.5 text-sm text-gray-700 dark:text-gray-200") { cx[:expectation] }
        end
      end
      illustrations(cx[:illustrations]) if cx[:illustrations].present?
    end
  end

  def primary_label(cx)
    [ cx[:name] || "Capability", "Level #{@primary_cell[:level_ordinal]}" ].join(" · ")
  end

  def scope_label(cx)
    level = cx[:level_title].present? ? "#{cx[:level_title]} (Level #{@primary_cell[:level_ordinal]})" : "Level #{@primary_cell[:level_ordinal]}"
    [ cx[:role], level, ("on #{cx[:assessee_name]}'s assessment" if cx[:assessee_name]) ].compact.join(" · ")
  end

  def illustrations(list)
    div do
      span(class: "block text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") { "Examples" }
      ul(class: "mt-1 space-y-1") do
        list.each do |text|
          li(class: "flex gap-2 text-sm text-gray-700 dark:text-gray-200") do
            span(class: "text-gray-400", aria: { hidden: "true" }) { "•" }
            span { text }
          end
        end
      end
    end
  end

  def hidden_fields
    input(type: "hidden", name: "evidence[assignment_id]", value: @assignment_id)
    input(type: "hidden", name: "evidence[evidence_id]", value: @evidence&.id) if @evidence
    input(type: "hidden", name: "evidence[request_id]", value: @request&.id) if @request
    input(type: "hidden", name: "return_to", value: @return_to)
    # The primary cell, explicit so the server can split it from the extras, and
    # always part of the desired link set.
    input(type: "hidden", name: "evidence[primary_cell]", value: primary_token)
    input(type: "hidden", name: "evidence[desired_links][]", value: primary_token)
  end

  def content_fields
    unless @content_editable
      p(class: "text-xs text-amber-700 dark:text-amber-400") do
        "You're linking #{@evidence&.author&.name || "someone else"}'s feedback — the content can't be edited here, only where it applies."
      end
    end
    type_field
    custom_label_field
    title_field
    content_field
    external_fields
  end

  def type_field
    div do
      label(for: "evm-type", class: LABEL) { "Type" }
      select(id: "evm-type", name: "evidence[evidence_type]", class: INPUT, disabled: !@content_editable,
             data: { evidence_modal_target: "typeSelect", action: "change->evidence-modal#typeChanged" }) do
        TYPE_OPTIONS.each { |text, value| option(value: value, selected: value == selected_type) { text } }
      end
    end
  end

  def custom_label_field
    div(class: (selected_type == "other" ? nil : "hidden"), data: { evidence_modal_target: "customLabel" }) do
      label(for: "evm-custom", class: LABEL) { "Describe the type" }
      input(id: "evm-custom", type: "text", name: "evidence[custom_type_label]", value: @evidence&.custom_type_label,
            maxlength: 60, class: INPUT, disabled: !@content_editable)
    end
  end

  def title_field
    div do
      label(for: "evm-title", class: LABEL) { "Title (optional)" }
      input(id: "evm-title", type: "text", name: "evidence[title]", value: @evidence&.title,
            maxlength: 120, class: INPUT, disabled: !@content_editable)
    end
  end

  def content_field
    div do
      label(for: "evm-content", class: LABEL) { "What happened?" }
      textarea(id: "evm-content", name: "evidence[content]", rows: 4, required: @content_editable,
               placeholder: "Describe what you observed…", class: INPUT, disabled: !@content_editable) { @evidence&.content }
    end
  end

  def external_fields
    div(class: "grid grid-cols-2 gap-2") do
      div do
        label(for: "evm-sys", class: LABEL) { "Link to (optional)" }
        select(id: "evm-sys", name: "evidence[external_reference][system]", class: INPUT, disabled: !@content_editable) do
          SYSTEM_OPTIONS.each { |text, value| option(value: value, selected: value == @evidence&.external_reference&.system) { text } }
        end
      end
      div do
        label(for: "evm-url", class: LABEL) { "URL" }
        input(id: "evm-url", type: "url", name: "evidence[external_reference][url]", value: @evidence&.external_reference&.url,
              placeholder: "https://", class: INPUT, disabled: !@content_editable)
      end
    end
  end

  # "Also applies to" — pick extra cells; each renders as a row with that cell's
  # behavioural expectation so the user sees which behaviour it must satisfy.
  def links_section
    div(class: "pt-2 border-t border-gray-100 dark:border-gray-800") do
      span(class: "block text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300 mb-1") { "Also applies to" }
      picker_row
      div(class: "mt-2 space-y-2", data: { evidence_modal_target: "linkRows" }) do
        @linked_cells.each { |cell| link_row(cell) }
      end
    end
  end

  def picker_row
    div(class: "flex flex-wrap items-end gap-2") do
      div(class: "flex-1 min-w-40") do
        select(class: INPUT, aria: { label: "Capability to also link" },
               data: { evidence_modal_target: "linkCapability", action: "change->evidence-modal#capabilityChanged" }) do
          option(value: "") { "Capability…" }
          @link_options.each do |group|
            optgroup(label: group[:category_name]) do
              group[:capabilities].each { |cap| option(value: cap[:stable_id]) { cap[:name] } }
            end
          end
        end
      end
      # Levels are populated by the controller from the chosen capability's valid
      # cells, with already-linked levels disabled (see #capabilityChanged).
      div(class: "w-44") do
        select(class: INPUT, data: { evidence_modal_target: "linkLevel" }, aria: { label: "Level to also link" }) do
          option(value: "") { "Level…" }
        end
      end
      button(type: "button", data: { action: "evidence-modal#addLink" }, class: SECONDARY_BTN) { "+ Add" }
    end
  end

  def link_row(cell)
    div(class: "rounded-md border border-gray-200 dark:border-gray-700 p-2 text-sm", data: { link_row: "" }) do
      div(class: "flex items-start justify-between gap-2") do
        span(class: "font-medium text-gray-900 dark:text-white") { "#{cell[:capability_name] || "Capability"} · L#{cell[:level_ordinal]}" }
        button(type: "button", aria: { label: "Remove link" }, data: { action: "evidence-modal#removeLink" },
               class: "text-gray-400 hover:text-gray-700 dark:hover:text-gray-200 cursor-pointer") { "×" }
      end
      p(class: "mt-0.5 text-xs text-gray-600 dark:text-gray-300") { "↳ #{cell[:expectation]}" } if cell[:expectation].present?
      input(type: "hidden", name: "evidence[desired_links][]", value: "#{cell[:capability_stable_id]}|#{cell[:level_ordinal]}")
    end
  end

  # Per-cell expectation map (valid cells + their expectation) for the Stimulus
  # controller to drive the level dropdown and render new rows.
  def expectation_data
    json = JSON.generate(@expectation_map).gsub("</", '<\/')
    script(type: "application/json", data: { evidence_modal_target: "expectations" }) { raw(safe(json)) }
  end

  # Level ordinal → label, for the dynamically-populated level dropdown.
  def level_data
    json = JSON.generate(@level_options).gsub("</", '<\/')
    script(type: "application/json", data: { evidence_modal_target: "levels" }) { raw(safe(json)) }
  end

  def footer
    div(class: "flex justify-end gap-2 pt-2") do
      button(type: "button", data: { action: "modal#close" }, class: SECONDARY_BTN) { "Cancel" }
      button(type: "submit",
             class: "inline-flex items-center min-h-11 px-4 rounded-md bg-primary text-white text-sm font-medium hover:opacity-90 cursor-pointer") { submit_label }
    end
  end

  def submit_label
    { new: "Add feedback / evidence", edit: "Save changes", respond: "Provide feedback / evidence" }.fetch(@mode)
  end

  def selected_type
    @evidence&.evidence_type.presence || "peer_feedback"
  end

  def primary_token
    "#{@primary_cell[:capability_stable_id]}|#{@primary_cell[:level_ordinal]}"
  end

  # Raw path (not a named helper) so the component renders before the save
  # routes land; wired per-surface in later commits.
  def form_action
    if assessment_surface?
      "/assessments/#{@assignment_id}/evidence/save"
    elsif @mode == :respond
      "/evidence_requests/#{@request.id}/respond"
    else
      "/evidence_items/#{@evidence.id}"
    end
  end

  def form_method
    (@mode == :edit && !assessment_surface?) ? "patch" : "post"
  end

  def assessment_surface?
    @return_to.to_s.start_with?("assessment:")
  end
end
