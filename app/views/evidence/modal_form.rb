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
  include Views::Evidence::ExamplesDisclosure

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

  INPUT = Components::Kit::Field::INPUT
  SELECT = Components::Kit::Field::SELECT
  LABEL = "block text-xs font-medium text-muted mb-1"

  # @param mode [Symbol, String] :new, :edit, or :respond
  # @param assignment_id [String]
  # @param content_editable [Boolean] whether the content fields are enabled
  # @param seed_cell [Hash, nil] the fixed origin cell (:new / :respond only)
  # @param context_block [Hash, nil] writing-prompt context (:new / :respond only)
  # @param scope_line [String, nil] "on ⟨name⟩'s assessment · ⟨role⟩" for hub-opened :edit
  # @param link_options [Array<Hash>] capability picker options, grouped by category
  # @param level_options [Array<Hash>] [{ ordinal:, label: }] for the level picker + row titles
  # @param linked_cells [Array<Hash>] ALL active links as rows, entry point first (:edit only),
  #   then any placement suggestions staged by "Adjust" (rows carrying `suggestion_id:`)
  # @param expectation_map [Hash{String=>Hash}] cell token => { capability_name:, expectation:, illustrations: }
  # @param evidence [EvidenceItem, nil]
  # @param request [EvidenceRequest, nil]
  # @param return_to [String, nil] "hub" or "assessment:<id>" — picks the submit endpoint
  # @param recipient [Hash, nil] { name:, scope: } — whose assessment this lands on, for
  #   the forms with no cell card (volunteered :new, :edit of an unplaced item)
  # @param draft [FeedbackDraft, nil] a Slack draft to prefill a volunteered :new from
  def initialize(mode:, assignment_id:, content_editable:, seed_cell: nil, context_block: nil,
                 scope_line: nil, link_options: [], level_options: [], linked_cells: [],
                 expectation_map: {}, evidence: nil, request: nil, return_to: nil, recipient: nil, draft: nil)
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
    @recipient = recipient
    @draft = draft
  end

  def view_template
    turbo_frame_tag("evidence-modal") do
      # The flag is a string: Phlex renders a bare attribute for `true`, and a
      # Stimulus Boolean reads "false" as false but an empty value as true.
      div(class: "p-5", data: { controller: "evidence-modal", evidence_modal_allow_unplaced_value: allow_unplaced?.to_s }) do
        header
        context_card if @context_block
        recipient_line if @recipient
        hub_scope_line if @scope_line
        visibility_note
        # _top so the submit isn't captured by the #evidence-modal frame: the
        # hub's redirect must navigate the page, and turbo_stream responses (the
        # assessment surface) still apply globally regardless of frame target.
        form_with(url: form_action, method: form_method, class: "space-y-3",
                  data: { turbo_frame: "_top", controller: "submit-guard",
                          action: "turbo:submit-end->modal#submitted " \
                                  "submit->submit-guard#guard " \
                                  "turbo:submit-start->submit-guard#start " \
                                  "turbo:submit-end->submit-guard#end" }) do
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
      h2(class: "text-base font-semibold text-default") { title }
      render Components::Kit::Button.new(variant: :ghost, icon: true, aria_label: "Close",
                                         data: { action: "modal#close" }) { "×" }
    end
  end

  def title
    return "Give feedback" if volunteered?

    { new: "Add feedback / evidence", edit: "Edit feedback / evidence", respond: "Provide feedback / evidence" }.fetch(@mode)
  end

  # A :new with no cell — feedback volunteered from the hub or Slack, not
  # written from a cell on the assessment.
  def volunteered?
    @mode == :new && @seed_cell.nil?
  end

  # Whether the form may be submitted with no "Applies to" row: volunteered
  # feedback, and the edit of an item still unplaced. Everywhere else an item
  # must keep at least one row.
  def allow_unplaced?
    volunteered? || (@mode == :edit && existing_links.empty?)
  end

  # The item's own links, without suggestion rows staged beside them.
  def existing_links
    @linked_cells.reject { |cell| cell[:suggestion_id] }
  end

  def staged_suggestion_ids
    @linked_cells.filter_map { |cell| cell[:suggestion_id] }
  end

  # Whose assessment, for a form with no cell card.
  def recipient_line
    p(class: "text-sm text-muted mb-3") do
      plain "For "
      span(class: "font-medium text-default") { @recipient[:name] }
      plain " · #{@recipient[:scope]}" if @recipient[:scope]
    end
  end

  # Writing-prompt context for :new / :respond — the behaviour being written
  # about (capability · level, the expectation, examples behind a disclosure)
  # sits above the content fields while composing. :edit renders no top card:
  # all context lives on the uniform "Applies to" rows.
  def context_card
    cx = @context_block
    render Components::Kit::Card.new(variant: :inset, density: :compact, class: "mb-4") do |card|
      card.body { context_card_body(cx) }
    end
  end

  def context_card_body(cx)
    div(class: "space-y-2") do
      div do
        p(class: "text-sm font-medium text-default") { prompt_label(cx) }
        p(class: "text-xs text-muted") { scope_label(cx) } if cx[:show_role_level]
      end
      if cx[:expectation].present?
        div do
          span(class: "block text-xs font-semibold uppercase tracking-wide text-muted") { "What good looks like" }
          p(class: "mt-0.5 text-sm text-muted") { cx[:expectation] }
        end
      end
      examples_disclosure(cx[:illustrations], css: "text-sm") if cx[:illustrations].present?
    end
  end

  # Whose assessment (hub-opened :edit only — the hub lists items across
  # people, and edit mode has no prompt card to say so).
  def hub_scope_line
    p(class: "text-xs text-muted mb-3") { "Feedback #{@scope_line}" }
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
    assessee = if @mode == :respond && @request && @request.requestee_person_id != @request.person_id
      @context_block[:assessee_name].presence || "the assessee"
    elsif volunteered? && @recipient
      @recipient[:name]
    end
    return if assessee.nil?

    render Components::Kit::Alert.new(tone: :info, size: :sm, role: :note, class: "mb-4",
                                      data: { testid: "visibility-note" }) do
      "Your feedback will be added to #{assessee}'s assessment — visible to #{assessee}, their managers, and workspace admins."
    end
  end

  def hidden_fields
    input(type: "hidden", name: "evidence[assignment_id]", value: @assignment_id)
    input(type: "hidden", name: "evidence[evidence_id]", value: @evidence&.id) if @evidence
    input(type: "hidden", name: "evidence[request_id]", value: @request&.id) if @request
    input(type: "hidden", name: "return_to", value: @return_to)
    input(type: "hidden", name: "draft_token", value: @draft.token) if @draft
    # Every suggestion staged by "Adjust": one whose row is gone by the time
    # the form is saved was turned down (EvidenceDiffSubmit dismisses it).
    staged_suggestion_ids.each { |id| input(type: "hidden", name: "evidence[staged_suggestion_ids][]", value: id) }
    # The seed cell (:new / :respond only) — the record_evidence origin. Its
    # desired-link entry rides on the fixed seed row. :edit submits no seed;
    # the server diffs the desired set against current links.
    input(type: "hidden", name: "evidence[primary_cell]", value: seed_token) if @seed_cell
  end

  def content_fields
    unless @content_editable
      p(class: "text-xs text-warning") do
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
      select(id: "evm-type", name: "evidence[evidence_type]", class: SELECT, disabled: !@content_editable,
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
               placeholder: "Describe what you observed…", class: INPUT, disabled: !@content_editable,
               aria: { describedby: "evm-content-hint" }) { @evidence&.content || @draft&.content }
      p(id: "evm-content-hint", class: "mt-1 text-xs text-muted") do
        "#{Prose::COMPOSER_HINT}: **bold**, _italic_, lists and [a link](https://…). A pasted URL becomes a link."
      end
    end
  end

  def external_fields
    return imported_origin if external_reference&.imported?

    div(class: "grid grid-cols-2 gap-2") do
      div do
        label(for: "evm-sys", class: LABEL) { "Link to (optional)" }
        select(id: "evm-sys", name: "evidence[external_reference][system]", class: SELECT, disabled: !@content_editable) do
          SYSTEM_OPTIONS.each { |text, value| option(value: value, selected: value == external_reference&.system) { text } }
        end
      end
      div do
        label(for: "evm-url", class: LABEL) { "URL" }
        input(id: "evm-url", type: "url", name: "evidence[external_reference][url]", value: external_reference&.url,
              placeholder: "https://", class: INPUT, disabled: !@content_editable)
      end
    end
  end

  # Where an imported item was given is fixed; say so instead of offering fields.
  def imported_origin
    div(id: "evm-origin", class: "flex flex-wrap items-center gap-2 text-xs text-muted") do
      span(class: LABEL.sub("mb-1", "mb-0")) { "Given in" }
      render Views::Evidence::OriginBadge.new(external_reference, size: :sm)
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
    div(class: "pt-2 border-t border-subtle") do
      span(class: "block text-xs font-semibold uppercase tracking-wide text-muted mb-1") { "Applies to" }
      unplaced_hint if allow_unplaced?
      div(class: "space-y-2", data: { evidence_modal_target: "linkRows" }) do
        seed_row if @seed_cell
        @linked_cells.each { |cell| link_row(cell) }
      end
      picker_row
    end
  end

  # Feedback may be saved with no row: the recipient or their manager places
  # it later. Said before the picker so nobody hunts for a capability they
  # can't name.
  def unplaced_hint
    whose = @recipient ? @recipient[:name] : "the person"
    p(class: "text-xs text-muted mb-2", data: { testid: "unplaced-hint" }) do
      "Not sure which capability this speaks to? Save without one — #{whose} or their manager can place it."
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
               "#{entry ? "border-strong ring-1 ring-(--gos-border-strong)" : "border-default"}",
        title: (entry ? "You opened this feedback from here" : nil),
        data: { link_row: "" }) do
      div(class: "flex items-start justify-between gap-2") do
        span(class: "font-medium text-default") do
          "#{cell[:capability_name] || "Capability"} · #{level_label(cell[:level_ordinal])}"
        end
        remove_button if removable
      end
      suggested_note(cell) if cell[:suggestion_id]
      p(class: "text-xs text-muted") { "↳ #{cell[:expectation]}" } if cell[:expectation].present?
      if cell[:comment_count].to_i.positive?
        # Disclose an active discussion before the user stages this link's
        # removal — the thread is preserved in history either way.
        p(class: "text-xs italic text-muted") do
          "#{cell[:comment_count]} #{'comment'.pluralize(cell[:comment_count])} in discussion — " \
            "kept in history if this link is removed"
        end
      end
      valence_select(name: "evidence[link_valences][#{token}]", current: cell[:valence],
                     required: required_valence, id: valence_id, css: "#{SELECT} text-xs")
      examples_disclosure(cell[:illustrations], open: entry) if cell[:illustrations].present?
      input(type: "hidden", name: "evidence[desired_links][]", value: token)
      input(type: "hidden", name: "evidence[suggestion_ids][]", value: cell[:suggestion_id]) if cell[:suggestion_id]
    end
  end

  # A row staged from a placement suggestion says so, with the words the
  # suggestion rested on: the person is checking the model's reading, not
  # their own.
  def suggested_note(cell)
    p(class: "text-xs text-muted", data: { testid: "suggested-row" }) do
      span(class: "font-semibold") { "Suggested" }
      plain " — #{cell[:rationale]}" if cell[:rationale].present?
    end
  end

  # Removing the last remaining link is blocked (withdraw the item instead) —
  # server-rendered disabled when only one link exists; the Stimulus
  # controller keeps the state current as rows are added/removed.
  def remove_button
    last = @seed_cell.nil? && @linked_cells.size == 1 && !allow_unplaced?
    button(type: "button", aria: { label: "Remove link" }, data: { action: "evidence-modal#removeLink" },
           disabled: last,
           title: (last ? "Feedback must apply to at least one behaviour — withdraw it instead" : nil),
           class: "text-subtle hover:text-default cursor-pointer " \
                  "disabled:opacity-40 disabled:cursor-not-allowed") { "×" }
  end

  def picker_row
    div(class: "mt-2 flex flex-wrap items-end gap-2") do
      div(class: "flex-1 min-w-40") do
        select(class: SELECT, aria: { label: "Capability to also link" },
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
        select(class: SELECT, data: { evidence_modal_target: "linkLevel" }, aria: { label: "Level to also link" }) do
          option(value: "") { "Level…" }
        end
      end
      # The staged row carries the (required) valence dropdown — the picker
      # stays a plain capability + level pick.
      render Components::Kit::Button.new(variant: :outline, touch: true, data: { action: "evidence-modal#addLink" }) { "+ Add" }
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
      render Components::Kit::Button.new(variant: :outline, touch: true, data: { action: "modal#close" }) { "Cancel" }
      # Turbo owns the in-flight treatment: `data-turbo-submits-with` swaps the
      # label and `config.forms.submitter` ("disabled") disables the button,
      # both restored on `turbo:submit-end`. `submit-guard` on the form adds
      # only what Turbo can't — blocking a re-entrant submit (audit issue
      # #335). `min-w-44` limits how far the footer slides when the label
      # shortens; no single value fits all three labels exactly.
      render Components::Kit::Button.new(tone: :brand, touch: true, type: :submit, class: "min-w-44",
                                         data: { turbo_submits_with: "Saving…" }) { submit_label }
    end
  end

  def submit_label
    return "Give feedback" if volunteered?

    { new: "Add feedback / evidence", edit: "Save changes", respond: "Provide feedback / evidence" }.fetch(@mode)
  end

  def selected_type
    @evidence&.evidence_type.presence || @draft&.evidence_type.presence || "peer_feedback"
  end

  def external_reference
    @evidence&.external_reference || @draft&.external_reference
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
    elsif @mode == :new
      "/evidence_items"
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
