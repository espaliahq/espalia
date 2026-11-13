# frozen_string_literal: true

# People the unit drawer can name as an owner or place as a member (#124):
# anyone active in the tenant, found by name or email.
class OrgGraph::PersonCandidates
  LIMIT = 12

  # @param query [String, nil] words that must each match a name or email
  # @return [Array<Hash>] `{ person:, subtitle: }`, name-ordered
  def search(query, limit: LIMIT)
    tokens = query.to_s.strip.split(/\s+/).first(5)
    return [] if tokens.empty?

    scope = tokens.reduce(Person.active) do |people, token|
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(token)}%"
      people.where("people.name ILIKE :q OR people.email ILIKE :q", q: pattern)
    end
    scope.order(:name).limit(limit).map { |person| { person:, subtitle: person.job_title.presence } }
  end
end
