# frozen_string_literal: true

# Checks {OrgGraphPolicy} before an Org Graph command writes, and records the
# actor as the person who made the change.
#
# Every handler names its actor. A person's {AuthorizationContext} is checked
# against every command. {SYSTEM} is the system's own work: the HRIS sync, a
# retirement moving its members, a rake task. It is not checked, but it can't
# change a unit's own structure, which is always a person's call. A handler
# with no actor raises, so a path that forgets one fails instead of skipping
# the check.
module OrgGraph::Authorization
  # A refused command. The message says who may make the change.
  class Refused < Pundit::NotAuthorizedError; end

  # The actor for writes nobody makes in person.
  SYSTEM = Object.new.tap { |system| system.define_singleton_method(:inspect) { "OrgGraph::Authorization::SYSTEM" } }.freeze

  # The refusal for a change to a structure, shared with the Operations that
  # check before they read anything about it.
  #
  # @param unit [OrgUnit, nil] the declaring unit, nil for the organisation's
  # @return [String]
  def self.structure_refusal(unit)
    return "Only a tenant admin or an Org Graph editor can change the organisation's structure" unless unit

    "You can change #{unit.name}'s structure if you own #{unit.name} or a unit above it, " \
      "report to someone who does, or are an Org Graph editor"
  end

  private

  def actor!(actor)
    return actor if actor.equal?(SYSTEM) || actor.is_a?(AuthorizationContext)

    raise ArgumentError, "An Org Graph handler needs an actor: an AuthorizationContext, or " \
                         "OrgGraph::Authorization::SYSTEM for the system's own writes"
  end

  def system? = @actor.equal?(SYSTEM)

  def authorize_taxonomy!
    authorize!(:edit_taxonomy?) { OrgGraph::Authorization.structure_refusal(nil) }
  end

  # @param unit_id [String, nil] the declaring unit, nil for the organisation's
  def authorize_structure_of!(unit_id)
    return authorize_taxonomy! unless unit_id
    raise Refused, "The system cannot change a structure" if system?

    unit = unit_for(unit_id)
    authorize!(:edit_structure_of?, unit) { OrgGraph::Authorization.structure_refusal(unit) }
  end

  def authorize_structure!
    authorize!(:edit_structure?) do
      "Only a tenant admin or an Org Graph editor can change the providers or people's facts"
    end
  end

  def authorize_unit!(unit_id)
    return if system?

    unit = unit_for(unit_id)
    authorize!(:edit_unit?, unit) { "#{only_owners_of(unit)} can change #{unit_name(unit)}" }
  end

  # The refusal names only the unit retyped, never the unit whose structure
  # is in force there.
  #
  # @param unit_id [String] the unit retyped
  # @param structure_unit_id [String, nil] the declaring unit of the structure
  #   in force where it sits, nil for the organisation's
  def authorize_unit_kind!(unit_id, structure_unit_id)
    structure_unit = structure_unit_id && unit_for(structure_unit_id)
    authorize!(:change_unit_kind?, structure_unit) do
      name = unit_name(unit_for(unit_id))
      next "Only a tenant admin or an Org Graph editor can change #{name}'s type" unless structure_unit_id

      "You can change #{name}'s type if you own the unit whose structure it sits in or a unit above that, " \
        "report to someone who does, or are an Org Graph editor"
    end
  end

  def authorize_new_unit!(parent_id)
    return if system?

    parent = parent_id && unit_for(parent_id)
    authorize!(:create_unit?, parent) { cannot_place_beneath(parent_id, parent) }
  end

  def authorize_move_unit!(unit_id, parent_id)
    return if system?

    unit = unit_for(unit_id)
    parent = parent_id && unit_for(parent_id)
    authorize!(:move_unit?, unit, parent) do
      next "#{only_owners_of(unit)} can move #{unit_name(unit)}" unless policy.edit_unit?(unit)

      cannot_place_beneath(parent_id, parent)
    end
  end

  # A move between structures changes the types of both, so it needs the
  # right to change each. The refusal names neither, so a caller learns
  # nothing about either structure. A unit is nil while a Structure rebuild
  # empties org_units, and the check runs before the rebuild guard, so the
  # policy must answer without it.
  #
  # @param from [String, nil] the structure the unit leaves, nil for the organisation's
  # @param into [String, nil] the structure it joins, nil for the organisation's
  def authorize_move_across!(from, into)
    refusal = "You need the right to change both structures to move a unit between them"
    raise Refused, refusal if system?

    [ from, into ].uniq.each do |structure_unit_id|
      next authorize!(:edit_taxonomy?) { refusal } unless structure_unit_id

      authorize!(:edit_structure_of?, unit_for(structure_unit_id)) { refusal }
    end
  end

  def authorize_succession!(unit_ids)
    return if system?

    units = unit_ids.flatten.compact.map { |unit_id| unit_for(unit_id) }
    authorize!(:record_succession?, units) do
      refused = units.find { |unit| !policy.edit_unit?(unit) }
      "#{only_owners_of(refused)} can name #{unit_name(refused)} in a succession"
    end
  end

  def authorize_membership!(person_id, unit_id)
    return if system?

    member = Person.find_by(id: person_id)
    unit = unit_for(unit_id)
    authorize!(:edit_membership?, member, unit) do
      "#{only_managers_of(member)} or #{owners_of(unit)} can change this membership"
    end
  end

  def authorize_move_membership!(person_id, from_unit_id, to_unit_id)
    return if system?

    member = Person.find_by(id: person_id)
    from = unit_for(from_unit_id)
    to = unit_for(to_unit_id)
    authorize!(:move_membership?, member, from, to) do
      "#{only_managers_of(member)} or someone with rights over both #{unit_name(from)} and " \
        "#{unit_name(to)} can move this membership"
    end
  end

  def authorize!(predicate, *records)
    return if system?
    return if policy.public_send(predicate, *records)

    raise Refused, yield
  end

  # Names the actor in the event, unless the caller already named someone.
  def attributed(options, key)
    actor_id = @actor.person&.id unless system?
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
    "an owner of #{unit_name(unit)} or a unit above it, or someone they report to"
  end

  def only_managers_of(member)
    "Only a tenant admin, an Org Graph editor, #{member ? "#{member.name}'s" : 'their'} manager chain"
  end

  def unit_name(unit)
    unit&.name || "this unit"
  end
end
