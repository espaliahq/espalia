# frozen_string_literal: true

# Checks {OrgGraphPolicy} before an Org Graph command writes, and records the
# actor as the person who made the change.
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
    unit = unit_for(unit_id)
    authorize!(:edit_unit?, unit) { "#{only_owners_of(unit)} can change #{unit_name(unit)}" }
  end

  def authorize_new_unit!(parent_id)
    parent = parent_id && unit_for(parent_id)
    authorize!(:create_unit?, parent) { cannot_place_beneath(parent_id, parent) }
  end

  def authorize_move_unit!(unit_id, parent_id)
    unit = unit_for(unit_id)
    parent = parent_id && unit_for(parent_id)
    authorize!(:move_unit?, unit, parent) do
      next "#{only_owners_of(unit)} can move #{unit_name(unit)}" unless policy.edit_unit?(unit)

      cannot_place_beneath(parent_id, parent)
    end
  end

  def authorize_succession!(unit_ids)
    units = unit_ids.flatten.compact.map { |unit_id| unit_for(unit_id) }
    authorize!(:record_succession?, units) do
      refused = units.find { |unit| !policy.edit_unit?(unit) }
      "#{only_owners_of(refused)} can name #{unit_name(refused)} in a succession"
    end
  end

  def authorize_membership!(person_id, unit_id)
    member = Person.find_by(id: person_id)
    unit = unit_for(unit_id)
    authorize!(:edit_membership?, member, unit) do
      "#{only_managers_of(member)} or #{owners_of(unit)} can change this membership"
    end
  end

  def authorize_move_membership!(person_id, from_unit_id, to_unit_id)
    member = Person.find_by(id: person_id)
    from = unit_for(from_unit_id)
    to = unit_for(to_unit_id)
    authorize!(:move_membership?, member, from, to) do
      "#{only_managers_of(member)} or someone with rights over both #{unit_name(from)} and " \
        "#{unit_name(to)} can move this membership"
    end
  end

  def authorize!(predicate, *records)
    return unless @actor
    return if policy.public_send(predicate, *records)

    raise Refused, yield
  end

  # Names the actor in the event, unless the caller already named someone.
  def attributed(options, key)
    actor_id = @actor&.person&.id
    actor_id ? { key => actor_id }.merge(options) : options
  end

  def policy
    @policy ||= OrgGraphPolicy.new(@actor, :org_graph)
  end

  def unit_for(unit_id)
    OrgUnit.find_by(id: unit_id.to_s.downcase)
  end

  def cannot_place_beneath(parent_id, parent)
    return "Only a tenant admin or an Org Graph editor can place a unit at the root" unless parent_id

    "#{only_owners_of(parent)} can place a unit beneath #{unit_name(parent)}"
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
