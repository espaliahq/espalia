# frozen_string_literal: true

# Who is in a plan, and as what.
class Operations::TeamPlanning::PlanMembers < Operations::Base
  include Operations::TeamPlanning::PlanRead

  description "List the members of a Team Planning plan the caller is in, each a person id, their name, a " \
              "role (editor or viewer) and see_pay: whether they hold the see-pay right. A holder also has " \
              "see_pay_granted, saying who granted it, when, and whether a tenant admin restored it to a " \
              "plan locked out of pay. A forgotten person reads as \"#{Person::FORMER_MEMBER}\". Refused, as an " \
              "unknown plan, unless the caller is a member."
  category :read
  approval :none

  parameter :plan_id, String, required: true

  # @return [Hash] `{ plan_id, members: [{ person_id, name, role, see_pay, see_pay_granted? }] }`
  def perform
    plan = plan!
    ids = plan.members.flat_map { [ it.person_id, it.see_pay_granted_by_id ] }.compact
    names = Person.where(id: ids).pluck(:id, :name).to_h
    name_of = ->(id) { names.fetch(id, Person::FORMER_MEMBER) }
    members = plan.members.map do |member|
      entry = { person_id: member.person_id, name: name_of.call(member.person_id), role: member.role, see_pay: member.see_pay }
      entry[:see_pay_granted] = granted(member, name_of) if member.see_pay
      entry
    end
    members.sort_by! { it.values_at(:role, :name, :person_id) }
    { plan_id: plan.id, members: members }
  end

  private

  def granted(member, name_of)
    by_id = member.see_pay_granted_by_id
    { by_id: by_id, by_name: (name_of.call(by_id) if by_id), at: member.see_pay_granted_at&.iso8601,
      recovery: member.see_pay_by_recovery }
  end
end
