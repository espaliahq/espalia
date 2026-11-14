# frozen_string_literal: true

# Who holds each email while the sync's first pass walks HiBob's response.
# The walk writes in response order, so each write frees one email and
# claims another. A dry run keeps the same book without writing, so it
# reaches the decisions the sync would.
class Hris::Hibob::EmailClaims
  # @!attribute [r] person_id
  #   @return [String, nil] nil for a newcomer a dry run has yet to create
  Claim = Data.define(:person_id, :external_id)

  def initialize
    @claims = {}
  end

  # @param email [String, nil]
  # @return [Claim, nil] whoever holds the email now, nil once it is freed
  def holder(email)
    return if email.blank?

    @claims.fetch(email) { @claims[email] = stored(email) }
  end

  # The unique index refuses an email another row holds.
  #
  # @param person [Person] with the email it would be saved with
  # @return [Boolean]
  def taken?(person)
    claim = holder(person.email)
    return false unless claim

    person.persisted? ? claim.person_id != person.id : claim.external_id != person.external_id
  end

  # Records a write: the person gives up the email they held and claims the one they now hold.
  #
  # @param person [Person]
  # @param from [String, nil] the email the person held before
  def move(person, from:)
    @claims[from] = nil if from.present? && from != person.email
    @claims[person.email] = Claim.new(person.id, person.external_id) if person.email.present?
  end

  private

  def stored(email)
    Person.where(email:).pick(:id, :external_id)&.then { Claim.new(*it) }
  end
end
