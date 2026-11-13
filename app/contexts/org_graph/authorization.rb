# frozen_string_literal: true

# Checks {OrgGraphPolicy} before an Org Graph command writes.
#
# A handler built with an actor checks every command against that actor. One
# built without one is the system: the HRIS sync, a retirement moving its
# members, a rake task. Nobody is acting, so nothing is checked.
module OrgGraph::Authorization
  # A refused command. The message says who may make the change.
  class Refused < Pundit::NotAuthorizedError; end

  private

  def authorize_structure!
    authorize!(:edit_structure?) do
      "Only a tenant admin or an Org Graph editor can change the taxonomy, its providers or people's facts"
    end
  end

  def authorize_unit!(unit_id)
    unit = find_unit(unit_id)
    authorize!(:edit_unit?, unit) { "#{only_owners_of(unit)} can change #{unit_name(unit)}" }
  end

  def authorize_units!(*unit_ids)
    unit_ids.flatten.compact.each { |unit_id| authorize_unit!(unit_id) }
  end

  def authorize_new_unit!(parent_id)
    return authorize_root! unless parent_id

    parent = find_unit(parent_id)
    authorize!(:create_unit?, parent) { "#{only_owners_of(parent)} can add a unit beneath #{unit_name(parent)}" }
  end

  def authorize_move_unit!(unit_id, parent_id)
    authorize_unit!(unit_id)
    authorize_new_unit!(parent_id)
  end

  def authorize_membership!(person_id, unit_id)
    member = Person.find_by(id: person_id)
    unit = find_unit(unit_id)
    authorize!(:edit_membership?, member, unit) do
      "#{only_managers_of(member)} or #{owners_of(unit)} can change this membership"
    end
  end

  def authorize_move_membership!(person_id, from_unit_id, to_unit_id)
    member = Person.find_by(id: person_id)
    from = find_unit(from_unit_id)
    to = find_unit(to_unit_id)
    authorize!(:move_membership?, member, from, to) do
      "#{only_managers_of(member)} or #{owners_of(from)} and of #{unit_name(to)} can move this membership"
    end
  end

  def authorize_root!
    authorize!(:edit_structure?) { "Only a tenant admin or an Org Graph editor can place a unit at the root" }
  end

  def authorize!(predicate, *records)
    return unless @actor
    return if OrgGraphPolicy.new(@actor, :org_graph).public_send(predicate, *records)

    raise Refused, yield
  end

  def find_unit(unit_id)
    OrgUnit.find_by(id: unit_id.to_s.downcase)
  end

  def only_owners_of(unit)
    "Only a tenant admin, an Org Graph editor or #{owners_of(unit)}"
  end

  def owners_of(unit)
    "an owner of #{unit_name(unit)} or a unit above it"
  end

  def only_managers_of(member)
    "Only a tenant admin, an Org Graph editor, #{member ? "#{member.name}'s" : 'their'} manager chain"
  end

  def unit_name(unit)
    unit&.name || "this unit"
  end
end
