# frozen_string_literal: true

# Authorization for calibration sessions.
#
# V1 is facilitator-only: the session surfaces (setup, overview,
# drill-in) are visible to the session's facilitator and tenant/global
# admins — NEVER to the participant raters, whose access is the
# projected screen in the room (see
# docs/architecture/calibration-sessions.md, "Access model"). The
# facilitator being an ancestor of the whole population is what makes
# the underlying assessment reads authorized without any new grants.
#
# Creating a session requires managing managers — someone in the
# caller's org subtree must themselves have reports (the department-head
# shape) — or tenant admin. Either way a linked Person is required,
# because the caller becomes the session's facilitator_id.
#
class CalibrationSessionPolicy < ApplicationPolicy
  def index?
    can_facilitate?
  end

  # Define a new session. Requires a linked Person even for admins —
  # the caller is recorded as the facilitator on the stream.
  def define?
    person.present? && can_facilitate?
  end

  def show?
    facilitator? || tenant_admin?
  end

  # Draft curation: add/remove participants and calibrants.
  def curate?
    facilitator? || tenant_admin?
  end

  def start?
    facilitator? || tenant_admin?
  end

  def close?
    facilitator? || tenant_admin?
  end

  # Live-session outcomes (flagging an expectation as unclear). The flag is
  # raised on the SESSION's authority — deliberately independent of framework
  # collaborator roles; the facilitator holds the room.
  def flag_expectation?
    facilitator? || tenant_admin?
  end

  private

  def can_facilitate?
    tenant_admin? || manages_managers?
  end

  # Whether the caller is a manager of managers — the shared
  # {Person#manages_managers?} predicate (also read by the nav link).
  def manages_managers?
    return false unless person

    person.manages_managers?
  end

  def facilitator?
    person.present? && record.respond_to?(:facilitator_id) && record.facilitator_id == person.id
  end
end
