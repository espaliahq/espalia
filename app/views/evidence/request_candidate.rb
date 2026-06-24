# frozen_string_literal: true

# One candidate the requester can add to the recipient list — used for both the
# typeahead **search results** (`compact: false`, full rows) and the quick-add
# **suggestions** (`compact: true`, chips). Clicking dispatches
# `request-evidence#add`, which moves the person into the selected-chips list
# client-side; the Stimulus controller reads the person's id/name from the
# data-params. A person who already has a pending request on the cell renders
# disabled ("Asked") so they can't be re-selected.
class Views::Evidence::RequestCandidate < Views::Base
  RELATION_LABELS = { assessee: "assessee", manager: "manager", peer: "peer", report: "report" }.freeze

  # @param candidate [Assessments::RequestCandidates::Candidate]
  # @param compact [Boolean] chip (suggestion) vs. row (search result)
  def initialize(candidate:, compact: false)
    @person = candidate.person
    @already_requested = candidate.already_requested
    @relation = candidate.relation
    @compact = compact
  end

  def view_template
    @already_requested ? disabled_el : add_el
  end

  private

  def add_el
    button(type: "button", class: classes,
           data: {
             action: "request-evidence#add",
             request_evidence_person_id_param: @person.id,
             request_evidence_name_param: @person.name,
             request_evidence_email_param: @person.email
           }) { inner }
  end

  def disabled_el
    span(class: "#{classes} opacity-50 cursor-not-allowed", aria: { disabled: "true" }) do
      inner(suffix: " · Asked")
    end
  end

  def inner(suffix: "")
    if @compact
      plain("#{plus} #{@person.name}#{relation_suffix}#{suffix}")
    else
      div(class: "min-w-0 text-left") do
        p(class: "truncate text-sm font-medium text-gray-900 dark:text-gray-100") { "#{@person.name}#{suffix}" }
        p(class: "truncate text-xs text-gray-600 dark:text-gray-300") { secondary }
      end
      span(class: "shrink-0 text-xs font-medium text-primary") { "Add" } unless @already_requested
    end
  end

  def secondary
    [ @person.email, @person.job_title.presence ].compact.join(" · ")
  end

  def relation_suffix
    @relation ? " (#{RELATION_LABELS[@relation]})" : ""
  end

  def plus
    @already_requested ? "" : "+"
  end

  def classes
    if @compact
      "inline-flex items-center min-h-9 px-2.5 rounded-full border border-gray-300 dark:border-gray-600 " \
        "text-xs font-medium text-gray-700 dark:text-gray-200 cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-800"
    else
      "flex w-full items-center justify-between gap-3 min-h-11 px-3 py-2 rounded-md " \
        "hover:bg-gray-50 dark:hover:bg-gray-800 cursor-pointer"
    end
  end
end
