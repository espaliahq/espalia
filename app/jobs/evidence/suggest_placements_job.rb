# frozen_string_literal: true

# Asks the model where a piece of feedback belongs and stores what it says as
# pending {EvidencePlacementSuggestion} rows for a person to decide on.
#
# Enqueued by {PersonDevelopment::AsyncHandlers::PlacementSuggester} when
# feedback is recorded or edited, and by the hub's "Suggest again". A no-op
# unless the tenant switched suggestions on and an API key is configured, and
# for self feedback. Each run supersedes the pending set it replaces. Nothing
# here can fail the write that triggered it: it runs after that write
# committed, and every failure ends in "no suggestions".
class Evidence::SuggestPlacementsJob < ApplicationJob
  queue_as :default

  GIVE_UP = ->(job, error) { Rails.logger.warn("[evidence-suggestions] #{job.arguments.first}: gave up, #{error.message}") }

  retry_on Evidence::SuggestionModel::RateLimited, wait: :polynomially_longer, attempts: 5, &GIVE_UP
  retry_on Evidence::SuggestionModel::Unavailable, wait: :polynomially_longer, attempts: 3, &GIVE_UP

  discard_on Evidence::SuggestionModel::Rejected do |job, error|
    Rails.logger.warn("[evidence-suggestions] #{job.arguments.first}: request rejected, #{error.message}")
  end

  # @param evidence_id [String]
  def perform(evidence_id)
    item = ActsAsTenant.without_tenant { EvidenceItem.find_by(id: evidence_id) }
    return if item.nil?

    ActsAsTenant.with_tenant(item.tenant) { generate(item) }
  end

  # Where whoever is asked to place the item hears that suggestions exist.
  # Deliberately empty here; the placement notifier hooks in
  # (https://github.com/mr-yum/growth-os/issues/534).
  #
  # @param item [EvidenceItem]
  def after_generate(item); end

  private

  def generate(item)
    return unless suggestable?(item)

    prompt = Evidence::PlacementPrompt.new(item)
    return unless prompt.available?

    asked_about = item.content
    model = Evidence::SuggestionModel.new(model: item.tenant.effective_ai_config.model)
    proposals = model.suggest(prompt).select { |p| usable?(prompt, p) }.uniq { |p| [ p.capability_stable_id, p.level_ordinal ] }
    after_generate(item) if store(item, proposals, model: model.model, asked_about: asked_about)
  end

  def suggestable?(item)
    item.tenant.evidence_suggestions_enabled? && Evidence::SuggestionModel.configured? &&
      item.link_status == "active" && item.source != "self"
  end

  # The schema keeps each field to known values; only the framework can say
  # which pairs exist, and what is already linked or was turned down.
  def usable?(prompt, proposal)
    prompt.open_cell?(proposal.capability_stable_id, proposal.level_ordinal) &&
      EvidenceLink::VALENCES.include?(proposal.valence) && proposal.rationale.present?
  end

  # Runs for one item are serialised (an edit and its original, or a double
  # "Suggest again", can overlap), and a run whose feedback was edited while
  # the model was answering stores nothing: the edit's own run is coming.
  #
  # @return [Boolean] whether a set was stored
  def store(item, proposals, model:, asked_about:)
    now = Time.current
    EvidencePlacementSuggestion.transaction do
      lock_item(item)
      next false if EvidenceItem.where(id: item.id).pick(:content) != asked_about

      EvidencePlacementSuggestion.for_evidence(item.id).pending.update_all(status: "superseded", updated_at: now)
      proposals.each { |proposal| upsert(item, proposal, model: model, at: now) }
      true
    end
  end

  def lock_item(item)
    key = ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtextextended(?, 0))", "placement-suggestions:#{item.id}" ])
    EvidencePlacementSuggestion.connection.execute(key)
  end

  # A superseded row for the same cell is reused (one row per cell); a cell
  # someone decided on is never reopened.
  def upsert(item, proposal, model:, at:)
    row = EvidencePlacementSuggestion.find_or_initialize_by(
      evidence_id: item.id, capability_stable_id: proposal.capability_stable_id, level_ordinal: proposal.level_ordinal
    )
    return if row.persisted? && row.status != "superseded"

    row.update!(
      person_id: item.person_id, framework_id: item.framework_id,
      valence: proposal.valence, confidence: proposal.confidence.round(2),
      rationale: proposal.rationale.truncate(EvidencePlacementSuggestion::RATIONALE_MAX_LENGTH),
      status: "pending", decided_by_id: nil, decided_at: nil, dismiss_reason: nil,
      model: model, prompt_version: Evidence::PlacementPrompt::VERSION, generated_at: at
    )
  end
end
