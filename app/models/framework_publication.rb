# frozen_string_literal: true

# A request to publish a framework draft, and how it ended.
#
# Publishing is heavy — it migrates every assigned person's ratings, evidence
# and comments onto the new version — so it runs in
# {Frameworks::PublishVersionJob} rather than the web request. This record is
# the durable handle between the two:
#
# * **one in flight per framework**: the partial unique index
#   `idx_framework_publications_one_in_flight` refuses a second `queued` /
#   `running` row, so a double submit is rejected at the database no matter
#   how many web processes race;
# * **truthful UI**: the Publish button renders disabled ("Publishing…") while
#   a row is in flight, on every reload and for every viewer;
# * **outcome**: `succeeded` carries the version; `failed` carries the
#   aggregate's message so the review page can show why.
#
# Plain ActiveRecord (like Tenant / Person), not a projection read model: it
# records coordination state, not domain facts. The domain fact is the
# `FrameworkVersionPublished` event the job produces.
class FrameworkPublication < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :tenant
  belongs_to :requested_by, class_name: "TenantUser"

  # Positional: the partial unique index hard-codes 0 = queued, 1 = running.
  enum :status, [ :queued, :running, :succeeded, :failed ]

  validates :framework_id, presence: true
  validates :draft_version, presence: true

  scope :in_flight, -> { where(status: [ :queued, :running ]) }
  scope :newest_first, -> { order(created_at: :desc) }

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
    where(framework_id: framework_id, draft_version: draft_version).newest_first.first
  end

  # @return [Boolean]
  def in_flight? = queued? || running?

  # @return [Person, nil] who asked for the publish
  def requester = requested_by.person
end
