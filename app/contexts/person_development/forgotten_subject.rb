# frozen_string_literal: true

# Refuses a write to the development stream of a person who has been
# forgotten. Only the subject counts: feedback a forgotten author wrote about
# a live person stays writable.
#
# It holds the person's row FOR KEY SHARE to the commit. An erase takes that
# row FOR UPDATE before it writes `forgotten_at`, so it either commits first
# and the refusal sees it, or waits until this command's events are stored.
# Key share doesn't block an ordinary update of the row, so a sync carries
# on. Take it before the stream is opened, and outside any savepoint, whose
# rollback would release it.
module PersonDevelopment::ForgottenSubject
  # The person was forgotten, so nothing more is written about them.
  class Forgotten < PersonDevelopment::Aggregate::CommandError
    # @param msg [String] what the hub and the MCP tools say; it names no one
    def initialize(msg = "this person has been forgotten") = super
  end

  # Holds the person's row until the surrounding transaction commits.
  #
  # @param person_id [String]
  # @raise [Forgotten] when the person has been forgotten
  # @return [void]
  def self.refuse!(person_id)
    raise Forgotten if Person.unscoped.where(id: person_id).lock("FOR KEY SHARE").pick(:forgotten_at)
  end

  # Runs the block in a transaction that holds the person's row first.
  #
  # @param person_id [String]
  # @return [Object] the block's value
  def self.writing(person_id)
    Person.transaction do
      refuse!(person_id)
      yield
    end
  end
end
