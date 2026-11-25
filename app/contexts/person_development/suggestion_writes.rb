# frozen_string_literal: true

# Runs a suggestion command on a person's development stream.
#
# It holds the person's row FOR KEY SHARE to the commit and refuses a
# forgotten person: a rationale quotes the feedback, and a dismissal can
# carry a typed reason. An erase takes that row FOR UPDATE before it writes
# `forgotten_at`, so it either commits first and the refusal sees it, or
# waits until this command's events are stored. Key share doesn't block an
# ordinary update of the row, so a sync carries on. The row comes first so a
# command waiting behind an erase holds nothing the job wants. It is taken
# outside the savepoint, whose rollback would release it.
#
# Then an advisory lock per evidence item, so runs and decisions for one
# item never overlap: an edit and its original, or a double "Suggest again".
#
# Two commands for one person write one stream, so the later one to store
# can lose the race even on another evidence item. It retries inside a
# savepoint, keeping the locks it holds.
module PersonDevelopment::SuggestionWrites
  ATTEMPTS = 3

  # The person was forgotten, so nothing more is written about them.
  class Forgotten < PersonDevelopment::Aggregate::CommandError
    def initialize(msg = "this person has been forgotten") = super
  end

  # @param person_id [String]
  # @param framework_id [String]
  # @param evidence_ids [Array<String>] the items to lock
  # @yieldparam aggregate [PersonDevelopment::Aggregate] its events are stored after the block
  # @return [Object] the block's value
  def self.with_aggregate(person_id, framework_id, evidence_ids:)
    attempts = 0
    EvidencePlacementSuggestion.transaction do
      raise Forgotten if Person.unscoped.where(id: person_id).lock("FOR KEY SHARE").pick(:forgotten_at)
      evidence_ids.uniq.sort.each { lock_item(it) }
      begin
        attempts += 1
        EvidencePlacementSuggestion.transaction(requires_new: true) do
          result = nil
          PersonDevelopment::Repository.new.with_person_development(person_id, framework_id) do |aggregate|
            result = yield aggregate
          end
          result
        end
      rescue RubyEventStore::WrongExpectedEventVersion
        retry if attempts < ATTEMPTS
        raise
      end
    end
  end

  def self.lock_item(evidence_id)
    sql = ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtextextended(?, 0))",
                                                  "placement-suggestions:#{evidence_id}" ])
    EvidencePlacementSuggestion.connection.execute(sql)
  end
  private_class_method :lock_item
end
