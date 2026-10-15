# frozen_string_literal: true

# Who a person can give feedback to: every active colleague with a framework
# assignment, found by name or email, or — with no query — the giver's org
# neighbours (their manager, their peers, their reports). One row per
# assignment, since a person assessed in two frameworks can receive feedback
# in either.
#
# The giver is excluded (feedback on yourself is recorded from your own
# assessment page), and so is anyone without an assignment: there is no
# assessment for the feedback to land on. Tenant scoping is automatic via
# acts_as_tenant on Person and PersonFrameworkAssignment.
#
# @example
#   q = Assessments::FeedbackRecipients.new(giver: current_person)
#   q.search("pri")   # => [Recipient(person:, assignment:, relationship: "peer"), …]
#   q.suggestions     # => the giver's manager, peers and reports with assignments
class Assessments::FeedbackRecipients
  DEFAULT_LIMIT = 10
  MAX_LIMIT = 25

  # @!attribute person [Person]
  # @!attribute assignment [PersonFrameworkAssignment]
  # @!attribute relationship [String] "report" | "manager" | "peer", from the giver's side
  Recipient = Data.define(:person, :assignment, :relationship)

  # @param giver [Person] the person giving feedback
  def initialize(giver:)
    @giver = giver
  end

  # @param query [String, nil] matched against name or email; blank → {#suggestions}
  # @param limit [Integer]
  # @return [Array<Recipient>]
  # `limit` caps rows, and a person assessed in several frameworks is several
  # rows, so the people fetched are a ceiling and the rows are cut after.
  def call(query, limit: DEFAULT_LIMIT)
    limit = limit.to_i.clamp(1, MAX_LIMIT)
    return suggestions.first(limit) if query.blank?

    term = "%#{Person.sanitize_sql_like(query.strip)}%"
    people = selectable
      .where("people.name ILIKE :t OR people.email ILIKE :t", t: term)
      .order(:name)
      .limit(limit)
    recipients_for(people.to_a).first(limit)
  end

  # The giver's org neighbours who hold an assignment: manager first, then
  # peers (the manager's other reports), then direct reports.
  #
  # @return [Array<Recipient>]
  def suggestions
    manager = giver.manager
    neighbours = [ manager ]
    neighbours += manager.direct_reports.active.order(:name).to_a if manager
    neighbours += giver.direct_reports.active.order(:name).to_a
    people = neighbours.compact.uniq(&:id).reject { |p| p.id == giver.id || p.status != "active" }
    recipients_for(people)
  end

  private

  attr_reader :giver

  def selectable
    Person.active
      .where.not(id: giver.id)
      .where(id: PersonFrameworkAssignment.select(:person_id))
  end

  # @return [Array<Recipient>] in the order the people were given
  def recipients_for(people)
    return [] if people.empty?

    assignments = PersonFrameworkAssignment
      .where(person_id: people.map(&:id))
      .includes(:framework, :role, :level)
      .group_by(&:person_id)

    people.flat_map do |person|
      Array(assignments[person.id]).map do |assignment|
        Recipient.new(person: person, assignment: assignment, relationship: relationship_to(person))
      end
    end
  end

  # One walk of the giver's chain and one of their subtree, however many rows.
  def relationship_to(person)
    return "report" if report_ids.include?(person.id)
    return "manager" if manager_ids.include?(person.id)

    "peer"
  end

  def report_ids
    @report_ids ||= giver.all_reports.pluck(:id).to_set
  end

  def manager_ids
    @manager_ids ||= giver.manager_chain.map(&:id).to_set
  end
end
