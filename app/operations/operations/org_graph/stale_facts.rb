# frozen_string_literal: true

# Which of some people's memberships and facts have gone stale (#142), as the
# Units view and the unit drawer flag them. Ids only, never names of people.
class Operations::OrgGraph::StaleFacts < Operations::Base
  description "List which of the given people's memberships and facts are stale: Espalia holds them and nobody " \
              "has changed or confirmed them within the tenant's threshold. Each row has the person id, the " \
              "fact (\"membership\", or a fact such as \"site\" or \"title\"), the unit id for a membership, the " \
              "day it was last checked and the id of whoever checked it. Oldest first. A fact an HRIS holds is " \
              "never stale, since each sync confirms it. Admins only while the Org Graph is unfinished."
  category :read
  approval :none

  parameter :person_ids, Array, required: true,
            schema: { type: "array", items: { type: "string" }, description: "person_ids to look at" }

  # @return [OrgGraph::StaleFacts, nil] nil until {#call} has run
  attr_reader :stale

  def policy_check
    authorize :org_graph, :show_units?
  end

  # @return [Hash] `{ stale: [...] }`
  def perform
    @stale = ::OrgGraph::StaleFacts.new(person_ids: Array(params[:person_ids]).map { it.to_s.downcase })

    { stale: stale.to_a.map { |age| row(age) } }
  end

  private

  def row(age)
    { person_id: age.person_id, fact: age.fact, unit_id: age.unit_id,
      last_checked_on: age.checked_at.to_date, checked_by_id: age.checked_by_id }
  end
end
