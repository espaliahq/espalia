# frozen_string_literal: true

# Runs a suggestion command on a person's development stream once the stream
# has caught up with the suggestions table.
#
# Until [#539](https://github.com/espaliahq/espalia/issues/539) c5 the release
# before this one may still write that table during a deploy, so a command
# takes that release's locks first: the advisory lock its placement job takes
# per evidence item, then the stream's rows, as its accept and dismiss do.
# Under them the table can't move, so what the catch-up records and what the
# command then decides agree.
#
# Two commands for one person write one stream, so the later one to store
# can lose the race even on another evidence item. It retries inside a
# savepoint, keeping the locks it holds.
module PersonDevelopment::SuggestionWrites
  ATTEMPTS = 3

  # @param person_id [String]
  # @param framework_id [String]
  # @param evidence_ids [Array<String>] the items whose job lock to take
  # @yieldparam aggregate [PersonDevelopment::Aggregate] caught up; its events are stored after the block
  # @yieldparam caught_up [Integer] how many rows the catch-up recorded
  # @return [Object] the block's value
  def self.with_caught_up(person_id, framework_id, evidence_ids:)
    attempts = 0
    EvidencePlacementSuggestion.transaction do
      evidence_ids.uniq.sort.each { lock_item(it) }
      begin
        attempts += 1
        EvidencePlacementSuggestion.transaction(requires_new: true) do
          rows = EvidencePlacementSuggestion.where(person_id:, framework_id:).order(:id).lock.to_a
          result = nil
          PersonDevelopment::Repository.new.with_person_development(person_id, framework_id) do |aggregate|
            caught_up = aggregate.catch_up_suggestions(rows.map(&:attributes))
            result = yield aggregate, caught_up
          end
          result
        end
      rescue RubyEventStore::WrongExpectedEventVersion
        retry if attempts < ATTEMPTS
        raise
      end
    end
  end

  # The key `Evidence::SuggestPlacementsJob` takes; it must not change while
  # that job can still run directly.
  def self.lock_item(evidence_id)
    sql = ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtextextended(?, 0))",
                                                  "placement-suggestions:#{evidence_id}" ])
    EvidencePlacementSuggestion.connection.execute(sql)
  end
end
