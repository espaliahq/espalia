# frozen_string_literal: true

# The current person's evidence-request hub: requests addressed to them
# (incoming — respond / decline) and requests they made (outgoing — cancel).
# This is the surface notifications deep-link to.
class EvidenceHubController < ApplicationController
  before_action :require_person

  # GET /evidence
  def show
    authorize EvidenceRequest, :index?, policy_class: EvidenceRequestPolicy

    incoming = EvidenceRequest.incoming_for(current_person.id).recent_first.includes(:requester)
    outgoing = EvidenceRequest.outgoing_for(current_person.id).recent_first.includes(:requestee)

    requests = incoming.to_a + outgoing.to_a
    render Views::Evidence::HubView.new(
      incoming: incoming.to_a,
      outgoing: outgoing.to_a,
      cell_details: cell_details_for(requests),
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  end

  private

  def require_person
    head :forbidden unless current_person
  end

  # For each request, resolve the cell's capability name, the assessee's role
  # (and that role's level title) the request is scoped to, the behavioural
  # expectation, and the role illustrations — so the hub shows *which role* and
  # *what behaviour* the evidence is for without anyone looking it up.
  #
  # @return [Hash{String => Hash}] request_id =>
  #   { name:, role:, level_title:, expectation:, illustrations: [String] }
  def cell_details_for(requests)
    return {} if requests.empty?

    capability_ids = capability_id_lookup(requests)         # [framework_id, stable_id] => capability_id
    roles = assessee_role_lookup(requests)                  # [framework_id, person_id] => role_id
    role_names = role_name_lookup(roles.values)             # role_id => role name

    requests.each_with_object({}) do |req, acc|
      capability_id = capability_ids[[ req.framework_id, req.capability_stable_id ]]
      next if capability_id.nil?

      expectation = FrameworkState::BehaviouralExpectation
        .find_by(capability_id: capability_id, level_ordinal: req.level_ordinal)
      role_id = roles[[ req.framework_id, req.person_id ]]

      acc[req.id] = {
        name: FrameworkState::Capability.where(capability_id: capability_id).pick(:name),
        role: role_names[role_id],
        level_title: level_title_for(role_id, req.level_ordinal),
        expectation: expectation&.description,
        illustrations: illustrations_for(expectation, role_id)
      }
    end
  end

  def capability_id_lookup(requests)
    requests.group_by(&:framework_id).each_with_object({}) do |(framework_id, reqs), acc|
      FrameworkState::Capability
        .joins(:category)
        .where(stable_id: reqs.map(&:capability_stable_id).uniq)
        .merge(FrameworkState::CapabilityCategory.where(framework_id: framework_id))
        .pluck(:stable_id, :capability_id)
        .each { |stable_id, capability_id| acc[[ framework_id, stable_id ]] = capability_id }
    end
  end

  def assessee_role_lookup(requests)
    requests.map { |r| [ r.framework_id, r.person_id ] }.uniq.each_with_object({}) do |(framework_id, person_id), acc|
      acc[[ framework_id, person_id ]] =
        PersonFrameworkAssignment.where(framework_id: framework_id, person_id: person_id).pick(:role_id)
    end
  end

  def role_name_lookup(role_ids)
    ids = role_ids.compact.uniq
    return {} if ids.empty?

    FrameworkState::Role.where(role_id: ids).pluck(:role_id, :name).to_h
  end

  def level_title_for(role_id, level_ordinal)
    return nil if role_id.nil?

    FrameworkState::Level.where(role_id: role_id, ordinal: level_ordinal).pick(:title)
  end

  def illustrations_for(expectation, role_id)
    return [] if expectation.nil? || role_id.nil?

    FrameworkState::RoleIllustration
      .where(expectation_id: expectation.expectation_id, role_id: role_id)
      .order(:ordinal)
      .pluck(:description)
  end

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
