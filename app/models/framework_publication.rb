# frozen_string_literal: true

# A request to publish a framework draft, and how it ended.
#
# Publishing is heavy — it migrates every assigned person's ratings, evidence
# and comments onto the new version — so it runs in
# {Frameworks::PublishVersionJob} rather than the web request. This record is
# the durable handle between the two:
#
# * **one in flight per framework**: the partial unique index
#   `idx_framework_publications_one_in_flight` refuses a second unfinished
#   row, so a double submit is rejected at the database no matter how many
#   web processes race;
# * **truthful UI**: the Publish button renders disabled ("Publishing…") while
#   a row is in flight, on every reload and for every viewer;
# * **outcome**: `succeeded` carries the version; `failed` carries a message
#   the review page can show.
#
# "In flight" means `finished_at` is nil. Every exit from the job — success,
# domain refusal, or crash — stamps it, and {.reap_stale!} closes a row whose
# worker died before it could (SIGKILL, OOM), so a lock can never outlive the
# work it guards.
#
# Plain ActiveRecord (like Tenant / Person), not a projection read model: it
# records coordination state, not domain facts. The domain fact is the
# `FrameworkVersionPublished` event the job produces.
class FrameworkPublication < ApplicationRecord
  # Longer than any publish should take; a row still unfinished after this
  # was abandoned by its worker, not slow.
  STALE_AFTER = 2.hours

  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :requested_by, class_name: "TenantUser"

  enum :status, [ :queued, :running, :succeeded, :failed ]

  validates :framework_id, presence: true
  validates :draft_version, presence: true

  scope :in_flight, -> { where(finished_at: nil) }
  scope :stale, -> { in_flight.where(created_at: ...STALE_AFTER.ago) }

  # @param framework_id [String]
  # @return [Boolean] whether a publish of this framework is queued or running
  def self.in_flight_for?(framework_id)
    in_flight.exists?(framework_id: framework_id)
  end

  # The most recent request for a given draft — what the review page reports.
  #
  # @param framework_id [String]
  # @param draft_version [Integer]
  # @return [FrameworkPublication, nil]
  def self.latest_for(framework_id, draft_version)
    where(framework_id: framework_id, draft_version: draft_version).order(created_at: :desc).first
  end

  # Closes abandoned rows so they stop holding the in-flight lock. Called
  # before every new request; cheap when there is nothing to reap.
  #
  # @param framework_id [String]
  # @return [Integer] rows closed
  def self.reap_stale!(framework_id)
    stale.where(framework_id: framework_id).update_all(
      status: statuses[:failed],
      error_message: "The publish did not finish within #{STALE_AFTER.inspect} and was abandoned.",
      finished_at: Time.current, updated_at: Time.current
    )
  end

  # @return [Boolean]
  def in_flight? = finished_at.nil?

  # @return [Person, nil] who asked for the publish
  def requester = requested_by.person
end
