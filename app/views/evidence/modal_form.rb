# frozen_string_literal: true

# The unified evidence form, rendered into the `#evidence-modal` turbo-frame by
# EvidenceModalController. One component for new / edit / respond, across the
# assessment screen and the hub. Single source of TYPE_OPTIONS / SYSTEM_OPTIONS.
#
# Submits the FULL desired state (content + the complete set of linked cells +
# optional request_id); the server diffs and emits the minimal commands.
class Views::Evidence::ModalForm < Views::Base
  include Phlex::Rails::Helpers::FormWith
  include Views::Evidence::Valence

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

  def initialize(mode:, assignment_id:, content_editable:, seed_cell: nil, context_block: nil,
                 scope_line: nil, link_options: [], level_options: [], linked_cells: [],
                 expectation_map: {}, evidence: nil, request: nil, return_to: nil)
    @mode = mode.to_sym
    @assignment_id = assignment_id
    @seed_cell = seed_cell
    @content_editable = content_editable
    @context_block = context_block
    @scope_line = scope_line
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
        context_card if @context_block
        hub_scope_line if @scope_line
        visibility_note
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
          valence_data
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

  # Writing-prompt context for :new / :respond — the behaviour being written
  # about (capability · level, the expectation, examples behind a disclosure)
  # sits above the content fields while composing. :edit renders no top card:
  # all context lives on the uniform "Applies to" rows.
  def context_card
    cx = @context_block
    div(class: "rounded-md bg-gray-50 dark:bg-gray-800/60 border border-gray-100 dark:border-gray-700 p-3 space-y-2 mb-4") do
      div do
        p(class: "text-sm font-medium text-gray-900 dark:text-white") { prompt_label(cx) }
        p(class: "text-xs text-gray-600 dark:text-gray-300") { scope_label(cx) } if cx[:show_role_level]
      end
      if cx[:expectation].present?
        div do
          span(class: "block text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300") { "What good looks like" }
          p(class: "mt-0.5 text-sm text-gray-700 dark:text-gray-200") { cx[:expectation] }
        end
      end
      examples_disclosure(cx[:illustrations], css: "text-sm") if cx[:illustrations].present?
    end
  end

  # Whose assessment (hub-opened :edit only — the hub lists items across
  # people, and edit mode has no prompt card to say so).
  def hub_scope_line
    p(class: "text-xs text-gray-600 dark:text-gray-300 mb-3") { "Feedback #{@scope_line}" }
  end

  def prompt_label(cx)
    [ cx[:name] || "Capability", "Level #{@seed_cell[:level_ordinal]}" ].join(" · ")
  end

  def scope_label(cx)
    level = cx[:level_title].present? ? "#{cx[:level_title]} (Level #{@seed_cell[:level_ordinal]})" : "Level #{@seed_cell[:level_ordinal]}"
    [ cx[:role], level, ("on #{cx[:assessee_name]}'s assessment" if cx[:assessee_name]) ].compact.join(" · ")
  end

  # When responding to a request about someone ELSE's assessment, be explicit
  # about who will read the response before the requestee writes it: the
  # assessee themselves, their manager chain, and workspace admins
  # (EvidencePolicy view rules). Skipped when the requestee IS the assessee —
  # writing on your own assessment needs no warning.
  def visibility_note
    return unless @mode == :respond && @request && @request.requestee_person_id != @request.person_id

    assessee = @context_block[:assessee_name].presence || "the assessee"
    div(class: "rounded-md bg-blue-50 dark:bg-blue-900/30 border border-blue-100 dark:border-blue-800 px-3 py-2 mb-4",
        data: { testid: "visibility-note" }) do
      p(class: "text-xs text-blue-800 dark:text-blue-200") do
        "Your feedback will be added to #{assessee}'s assessment — visible to #{assessee}, their managers, and workspace admins."
      end
    end
  end

  # Collapsible examples list (role illustrations) — shared by the prompt card
  # and every "Applies to" row. Native <details>, no JS.
  def examples_disclosure(list, css: "text-xs", open: false)
    details(class: "group", open: open) do
      summary(class: "cursor-pointer select-none text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300 " \
                     "marker:content-none flex items-center gap-1") do
        span(class: "transition-transform group-open:rotate-90", aria: { hidden: "true" }) { "▸" }
        span { "Examples (#{list.size})" }
      end
      ul(class: "mt-1 space-y-1") do
        list.each do |text|
          li(class: "flex gap-2 #{css} text-gray-700 dark:text-gray-200") do
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
    # The seed cell (:new / :respond only) — the record_evidence origin. Its
    # desired-link entry rides on the fixed seed row. :edit submits no seed;
    # the server diffs the desired set against current links.
    input(type: "hidden", name: "evidence[primary_cell]", value: seed_token) if @seed_cell
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

  # The one valence dropdown, shared by every "Applies to" row. A blank
  # placeholder renders only while nothing is chosen (a classified link can
  # be re-classified but never cleared back to unspecified).
  def valence_select(name:, current:, required:, css:, id: nil, data: {})
    select(id: id, name: name, required: required, class: css, data: data,
           aria: { label: "Evidence valence" }) do
      option(value: "", selected: current.nil?) { "Valence…" } if current.nil?
      Views::Evidence::Valence::OPTIONS.each do |text, value|
        option(value: value, selected: value == current) { text }
      end
    end
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

  # "Applies to" — every behaviour this feedback is linked to, as uniform rows:
  # capability · level, the expectation, a per-row valence, and expandable
  # examples. :new / :respond seed the block with the origin cell as a fixed
  # (non-removable) row carrying the REQUIRED valence; :edit renders ALL
  # active links — the origin is not special — and any row can be removed
  # while more than one remains (an item must apply somewhere; the aggregate
  # enforces the same floor). The entry-point row (the cell the modal was
  # opened from) sorts first, highlighted, with its examples pre-expanded.
  def links_section
    div(class: "pt-2 border-t border-gray-100 dark:border-gray-800") do
      span(class: "block text-xs font-semibold uppercase tracking-wide text-gray-600 dark:text-gray-300 mb-1") { "Applies to" }
      div(class: "space-y-2", data: { evidence_modal_target: "linkRows" }) do
        seed_row if @seed_cell
        @linked_cells.each { |cell| link_row(cell) }
      end
      picker_row
    end
  end

  # The fixed origin row for :new / :respond — the cell the feedback is being
  # recorded against. Not removable (it anchors record_evidence / the
  # request), and its valence is the forced choice on every new item.
  def seed_row
    info = @expectation_map[seed_token] || {}
    cell = { capability_stable_id: @seed_cell[:capability_stable_id], level_ordinal: @seed_cell[:level_ordinal],
             capability_name: info[:capability_name] || @context_block&.dig(:name),
             expectation: info[:expectation], illustrations: info[:illustrations] || [] }
    link_row(cell, removable: false, required_valence: true, valence_id: "evm-valence")
  end

  def link_row(cell, removable: true, required_valence: false, valence_id: nil)
    token = "#{cell[:capability_stable_id]}|#{cell[:level_ordinal]}"
    entry = cell[:entry_point]
    div(class: "rounded-md border p-2 text-sm space-y-1 " \
               "#{entry ? "border-primary/40 ring-1 ring-primary/40" : "border-gray-200 dark:border-gray-700"}",
        title: (entry ? "You opened this feedback from here" : nil),
        data: { link_row: "" }) do
      div(class: "flex items-start justify-between gap-2") do
        span(class: "font-medium text-gray-900 dark:text-white") do
          "#{cell[:capability_name] || "Capability"} · #{level_label(cell[:level_ordinal])}"
        end
        remove_button if removable
      end
      p(class: "text-xs text-gray-600 dark:text-gray-300") { "↳ #{cell[:expectation]}" } if cell[:expectation].present?
      valence_select(name: "evidence[link_valences][#{token}]", current: cell[:valence],
                     required: required_valence, id: valence_id, css: "#{INPUT} text-xs")
      examples_disclosure(cell[:illustrations], open: entry) if cell[:illustrations].present?
      input(type: "hidden", name: "evidence[desired_links][]", value: token)
    end
  end

  # Removing the last remaining link is blocked (withdraw the item instead) —
  # server-rendered disabled when only one link exists; the Stimulus
  # controller keeps the state current as rows are added/removed.
  def remove_button
    last = @seed_cell.nil? && @linked_cells.size == 1
    button(type: "button", aria: { label: "Remove link" }, data: { action: "evidence-modal#removeLink" },
           disabled: last,
           title: (last ? "Feedback must apply to at least one behaviour — withdraw it instead" : nil),
           class: "text-gray-400 hover:text-gray-700 dark:hover:text-gray-200 cursor-pointer " \
                  "disabled:opacity-40 disabled:cursor-not-allowed") { "×" }
  end

  def picker_row
    div(class: "mt-2 flex flex-wrap items-end gap-2") do
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
      # The staged row carries the (required) valence dropdown — the picker
      # stays a plain capability + level pick.
      button(type: "button", data: { action: "evidence-modal#addLink" }, class: SECONDARY_BTN) { "+ Add" }
    end
  end

  # "L3 — Senior Engineer" when the role has a title for the ordinal.
  def level_label(ordinal)
    @level_labels ||= @level_options.to_h { |opt| [ opt[:ordinal], opt[:label] ] }
    @level_labels[ordinal] || "L#{ordinal}"
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

  # [label, value] valence options for rows the Stimulus controller creates.
  def valence_data
    json = JSON.generate(Views::Evidence::Valence::OPTIONS).gsub("</", '<\/')
    script(type: "application/json", data: { evidence_modal_target: "valences" }) { raw(safe(json)) }
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

  def seed_token
    "#{@seed_cell[:capability_stable_id]}|#{@seed_cell[:level_ordinal]}"
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
