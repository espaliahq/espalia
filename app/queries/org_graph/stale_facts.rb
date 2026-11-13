# frozen_string_literal: true

# Which of some people's facts have gone stale (#142): nobody has changed or
# confirmed them within the tenant's threshold. Read from `org_fact_ages`, so
# only a fact Espalia holds can be stale; an HRIS confirms its own every sync.
#
#   stale = OrgGraph::StaleFacts.new(person_ids: [ ada.id ])
#   stale.membership(ada.id, platform.id) # => OrgFactAge or nil
#   stale.facts(ada.id, %w[site country]) # => the stale ones of the pair
class OrgGraph::StaleFacts
  # The employment facts the person drawer shows, each with the facts it is
  # made of in `org_fact_ages`. Site and country are one row there, as are
  # employment type and FTE.
  EMPLOYMENT = {
    "title" => %w[title],
    "level" => %w[level],
    "manager" => %w[manager_id],
    "cost_centre" => %w[cost_centre],
    "site" => %w[site country],
    "employment" => %w[employment_type fte]
  }.freeze

  # @param person_ids [Enumerable<String>] the people to look at
  # @param tenant [Tenant]
  # @param now [Time]
  def initialize(person_ids:, tenant: ActsAsTenant.current_tenant, now: Time.current)
    @person_ids = person_ids.to_a.uniq
    @tenant = tenant
    @now = now
  end

  # @param person_id [String]
  # @param unit_id [String]
  # @return [OrgFactAge, nil] the stale membership, nil when it is fresh or an HRIS holds it
  def membership(person_id, unit_id) = rows[[ person_id, OrgGraph::FactConfirmation::MEMBERSHIP, unit_id ]]

  # @param person_id [String]
  # @param facts [Array<String>] fact keys as `org_fact_ages` names them
  # @return [Array<OrgFactAge>] the stale ones, oldest first
  def facts(person_id, facts) = facts.filter_map { |fact| rows[[ person_id, fact, nil ]] }.sort_by(&:checked_at)

  # @param person_id [String]
  # @param employment [String] a key of {EMPLOYMENT}
  # @return [Array<OrgFactAge>]
  def employment(person_id, employment) = facts(person_id, EMPLOYMENT.fetch(employment, []))

  private

  def rows
    @rows ||= if @person_ids.empty?
      {}
    else
      OrgFactAge.stale(@tenant, now: @now).where(person_id: @person_ids).includes(:checked_by)
                .index_by { |row| [ row.person_id, row.fact, row.unit_id ] }
    end
  end
end
