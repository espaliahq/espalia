# frozen_string_literal: true

# Who is in a plan, and as what.
class Operations::TeamPlanning::PlanMembers < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "List the members of a Team Planning plan the caller is in, each a person id, their name and a " \
              "role (editor or viewer). A forgotten person reads as \"#{Person::FORMER_MEMBER}\". Refused, as an " \
              "unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true

  # @return [Hash] `{ plan_id, members: [{ person_id, name, role }] }`
  def perform
    plan = plan!
    names = Person.where(id: plan.members.map(&:person_id)).pluck(:id, :name).to_h
    members = plan.members.map do
      { person_id: it.person_id, name: names.fetch(it.person_id, Person::FORMER_MEMBER), role: it.role }
    end
    members.sort_by! { it.values_at(:role, :name, :person_id) }
    { plan_id: plan.id, members: members }
  end
end
