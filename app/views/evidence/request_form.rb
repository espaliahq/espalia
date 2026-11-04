# frozen_string_literal: true

# The "request evidence" form, rendered into the `#evidence-request-modal`
# turbo-frame by EvidenceRequestsController#modal. Collects the recipients
# (typeahead search + the assessee's-org-neighbour suggestions, multi-select)
# and a single shared reason, then posts one request per recipient.
#
# Selection is client-side: `request-evidence` (in-frame instance) moves a
# candidate into the chips list and appends an `evidence_request[requestee_ids][]`
# hidden input; search results come from the `#request-candidates` frame.
class Views::Evidence::RequestForm < Views::Base
  include Phlex::Rails::Helpers::FormWith

  INPUT = Components::Kit::Field::INPUT
  LABEL = "block text-xs font-medium text-muted mb-1"

  # @param assignment_id [String]
  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  # @param context_block [Hash] CellContextResolver output (name, level_title, expectation, assessee_name…)
  # @param suggestions [Array<Assessments::RequestCandidates::Candidate>]
  # @param submit_url [String] POST target (evidence_requests_path)
  # @param candidates_url [String] GET base for the search frame (carries assignment + cell params)
  # @param preselected [Person, nil] already picked when the form opens
  def initialize(assignment_id:, capability_stable_id:, level_ordinal:, context_block:,
                 suggestions:, submit_url:, candidates_url:, preselected: nil)
    @assignment_id = assignment_id
    @capability_stable_id = capability_stable_id
    @level_ordinal = level_ordinal
    @context_block = context_block
    @suggestions = suggestions
    @submit_url = submit_url
    @candidates_url = candidates_url
    @preselected = preselected
  end

  def view_template
    turbo_frame_tag("evidence-request-modal") do
      div(class: "p-5", data: { controller: "request-evidence", request_evidence_candidates_url_value: @candidates_url,
                                request_evidence_preselect_id_value: @preselected&.id,
                                request_evidence_preselect_name_value: @preselected&.name }.compact) do
        header
        context_card
        # `submit-guard` blocks a re-entrant submit while one is in flight
        # (audit issue #335). It matters more here than on the evidence save:
        # `Operations::Assessments::RequestEvidence` mints a fresh `request_id`
        # per POST, so a double-submit sends — and notifies — every recipient
        # twice. Turbo owns the rest of the in-flight treatment (disabling the
        # submitter, the `data-turbo-submits-with` label swap).
        form_with(url: @submit_url, method: :post, class: "space-y-4",
                  data: { turbo_frame: "_top", controller: "submit-guard",
                          action: "turbo:submit-end->modal#submitted " \
                                  "submit->submit-guard#guard " \
                                  "turbo:submit-start->submit-guard#start " \
                                  "turbo:submit-end->submit-guard#end" }) do
          hidden_field("assignment_id", @assignment_id)
          hidden_field("capability_stable_id", @capability_stable_id)
          hidden_field("level_ordinal", @level_ordinal)
          recipients_section
          message_section
          footer
        end
      end
    end
  end

  private

  def header
    div(class: "flex items-start justify-between mb-3") do
      h2(class: "text-base font-semibold text-default") { "Request feedback / evidence" }
      render Components::Kit::Button.new(variant: :ghost, icon: true, aria_label: "Close",
                                         data: { action: "modal#close" }) { "×" }
    end
  end

  def context_card
    cx = @context_block
    render Components::Kit::Card.new(variant: :inset, density: :compact, class: "mb-4") do |card|
      card.body do
        p(class: "text-sm font-medium text-default") { "#{cx[:name]} · #{cx[:level_title]}" }
        p(class: "text-xs text-muted") { "on #{cx[:assessee_name]}'s assessment" } if cx[:assessee_name]
        if cx[:expectation].present?
          span(class: "mt-2 block text-xs font-semibold uppercase tracking-wide text-muted") { "What good looks like" }
          p(class: "mt-0.5 text-sm text-muted") { cx[:expectation] }
        end
      end
    end
  end

  def recipients_section
    div do
      label(class: LABEL) { "Who can speak to this?" }
      # The results float as a dropdown over the content below (absolute, inside
      # this relative wrapper) so typing never resizes the modal.
      div(class: "relative") do
        input(type: "search", placeholder: "Search by name or email…", class: INPUT,
              data: { request_evidence_target: "search", action: "input->request-evidence#search" })
        div(class: "absolute left-0 right-0 top-full mt-1 z-20") do
          render Views::Evidence::RequestCandidatesFrame.new(candidates: [], query: nil)
        end
      end
      suggestions_block
      div(class: "mt-3") do
        span(class: LABEL) { "Selected" }
        div(data: { request_evidence_target: "selected" }, class: "flex flex-wrap gap-2 min-h-9") do
          p(data: { request_evidence_target: "empty" }, class: "text-xs text-muted") { "No one selected yet." }
        end
        div(data: { request_evidence_target: "ids" }, class: "hidden")
      end
    end
  end

  def suggestions_block
    return if @suggestions.empty?

    div(class: "mt-3") do
      span(class: LABEL) { "Suggestions" }
      div(class: "flex flex-wrap gap-2", data: { request_evidence_target: "suggestions" }) do
        @suggestions.each { |candidate| render Views::Evidence::RequestCandidate.new(candidate:, compact: true) }
      end
    end
  end

  def message_section
    div do
      label(for: "evr-message", class: LABEL) { "Why you're asking (shared by all recipients)" }
      textarea(id: "evr-message", name: "evidence_request[message]", rows: 3, maxlength: 1000,
               placeholder: "What you'd like them to speak to…", class: INPUT)
      div(class: "mt-3") do
        label(for: "evr-due", class: LABEL) { "Due (optional)" }
        # color-scheme is set globally on date inputs (application.css) so the
        # native calendar glyph adapts to the active scheme — see that rule.
        input(type: "date", id: "evr-due", name: "evidence_request[due_at]", class: INPUT)
      end
    end
  end

  def footer
    div(class: "flex items-center justify-end gap-2 pt-2") do
      render Components::Kit::Button.new(variant: :outline, touch: true, data: { action: "modal#close" }) { "Cancel" }
      # Turbo swaps the button's innerHTML for "Sending…" and restores it on
      # `turbo:submit-end` — including the count span, whose Stimulus target
      # re-registers on the restored node. `min-w-44` (as on the evidence
      # modal's Save) limits how far the footer slides as the label changes.
      render Components::Kit::Button.new(tone: :brand, touch: true, type: :submit, disabled: true, class: "min-w-44",
                                         data: { request_evidence_target: "submit", turbo_submits_with: "Sending…" }) do
        span(data: { request_evidence_target: "label" }) { "Send requests" }
      end
    end
  end

  def hidden_field(name, value)
    input(type: "hidden", name: "evidence_request[#{name}]", value: value)
  end
end
