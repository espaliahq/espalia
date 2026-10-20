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
        p(class: "truncate text-sm font-medium text-default") { "#{@person.name}#{suffix}" }
        p(class: "truncate text-xs text-muted") { secondary }
      end
      span(class: "shrink-0 text-xs font-medium text-brand") { "Add" } unless @already_requested
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
      "inline-flex items-center min-h-9 px-2.5 rounded-full border border-emphasized " \
        "text-xs font-medium text-muted cursor-pointer hover:bg-hover"
    else
      "flex w-full items-center justify-between gap-3 min-h-11 px-3 py-2 rounded-md " \
        "hover:bg-hover cursor-pointer"
    end
  end
end
