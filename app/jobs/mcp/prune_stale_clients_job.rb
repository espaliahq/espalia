# frozen_string_literal: true

# Removes DCR-registered OAuth clients that haven't seen activity in
# `Mcp::Application::STALE_AFTER` (30 days by default). Every fresh `claude`
# install creates a new application via Dynamic Client Registration, so
# without this the oauth_applications table grows unbounded.
#
# Scope: only applications created via DCR (dynamically_registered_at is
# set). Manually-created admin apps are never touched. For each stale
# app, dependent grants + tokens are deleted first so the
# oauth_applications FK doesn't block the parent delete; this is
# explicit rather than ON DELETE CASCADE so the same FK keeps protecting
# admin-created rows against accidental destruction.
class Mcp::PruneStaleClientsJob < ApplicationJob
  queue_as :default

  # @param cutoff [ActiveSupport::Duration, Time, nil] override window;
  #   nil uses Mcp::Application::STALE_AFTER. Tests pass a Duration; ops
  #   can pass an absolute Time via a one-off enqueue.
  def perform(cutoff: nil)
    threshold = resolve_threshold(cutoff)
    stale = Mcp::Application.dcr_stale(cutoff: threshold).to_a
    return { deleted: 0 } if stale.empty?

    stale_ids = stale.map(&:id)

    Mcp::Application.transaction do
      Mcp::AccessToken.where(application_id: stale_ids).delete_all
      Mcp::AccessGrant.where(application_id: stale_ids).delete_all
      Mcp::Application.where(id: stale_ids).delete_all
    end

    Rails.logger.info("[mcp_prune] deleted #{stale.size} DCR clients older than #{threshold.iso8601}")
    { deleted: stale.size }
  end

  private

  def resolve_threshold(cutoff)
    case cutoff
    when nil                       then Mcp::Application::STALE_AFTER.ago
    when ActiveSupport::Duration   then cutoff.ago
    when Time, ActiveSupport::TimeWithZone then cutoff
    else raise ArgumentError, "unsupported cutoff #{cutoff.class}"
    end
  end
end
