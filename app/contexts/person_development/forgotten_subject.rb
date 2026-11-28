# frozen_string_literal: true

# Refuses a write to the development stream of a person who has been
# forgotten. Only the subject counts: feedback a forgotten author wrote about
# a live person stays writable.
#
# It holds the person's row FOR KEY SHARE to the commit. An erase takes that
# row FOR UPDATE before it writes `forgotten_at`, so it either commits first
# and the refusal sees it, or waits until this command's events are stored.
# Key share doesn't block a change to the person's name, manager or HRIS id,
# so a sync carries on. It does block a change to their email, which a unique
# index makes a key column: the sync's save waits for the write to commit.
# `PersonDevelopment::Repository#with_person_development` takes it before
# it opens the stream, so every write holds it. Inside a caller's savepoint a
# rollback releases it, and the retry takes it again as it reopens the stream.
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
    raise Forgotten if hold(person_id)
  end

  # Takes the same lock without refusing, for a caller that must lock before
  # it authorises. Its first write refuses as usual.
  #
  # @param person_id [String]
  # @return [Time, nil] when the person was forgotten
  def self.hold(person_id)
    Person.unscoped.where(id: person_id).lock("FOR KEY SHARE").pick(:forgotten_at)
  end
end
