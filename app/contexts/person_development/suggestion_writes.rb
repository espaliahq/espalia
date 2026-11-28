# frozen_string_literal: true

# Runs a suggestion command on a person's development stream.
#
# It refuses a forgotten person first, through
# {PersonDevelopment::ForgottenSubject}: a rationale quotes the feedback, and a
# dismissal can carry a typed reason. The person's row comes before anything
# else, so a command waiting behind an erase holds nothing the job wants. The
# repository refuses again as it opens the stream; the second key share is
# a no-op.
#
# Then an advisory lock per evidence item, so runs and decisions for one
# item never overlap: an edit and its original, or a double "Suggest again".
#
# Two commands for one person write one stream, so the later one to store
# can lose the race even on another evidence item. It retries inside a
# savepoint, keeping the locks it holds.
module PersonDevelopment::SuggestionWrites
  ATTEMPTS = 3

  Forgotten = PersonDevelopment::ForgottenSubject::Forgotten

  # @param person_id [String]
  # @param framework_id [String]
  # @param evidence_ids [Array<String>] the items to lock
  # @yieldparam aggregate [PersonDevelopment::Aggregate] its events are stored after the block
  # @return [Object] the block's value
  def self.with_aggregate(person_id, framework_id, evidence_ids:)
    attempts = 0
    EvidencePlacementSuggestion.transaction do
      PersonDevelopment::ForgottenSubject.refuse!(person_id)
      lock_items(evidence_ids)
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

  # Holds each item's lock to the commit. A caller that appends to the stream
  # before running a suggestion command takes it first, or it can deadlock
  # with a placement job that holds the lock and waits on that append.
  #
  # @param evidence_ids [Array<String>]
  # @return [void]
  def self.lock_items(evidence_ids)
    evidence_ids.uniq.sort.each do |evidence_id|
      sql = ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtextextended(?, 0))",
                                                    "placement-suggestions:#{evidence_id}" ])
      EvidencePlacementSuggestion.connection.execute(sql)
    end
  end
end
