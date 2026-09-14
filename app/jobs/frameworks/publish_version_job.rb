# frozen_string_literal: true

# Publishes a framework draft in the background.
#
# Publishing rebuilds the published projection and then, in the same
# transaction, migrates every assigned person's ratings, evidence and comments
# onto the new version (`FrameworkVersionMigrationSync`) — one PersonDev stream
# replay per person. For a real framework that is far too slow for a web
# request, so {Operations::Frameworks::PublishVersion} records a
# {FrameworkPublication} and enqueues this job; the record is what the UI
# reads to show "Publishing…" and to refuse a second request while this runs.
#
# Authorization is re-checked here as the requester (their TenantUser rebuilds
# the same {AuthorizationContext} the web uses), so a publish right revoked
# between request and run is refused rather than honoured.
#
# The record's lifecycle is the invariant: every exit — success, a domain
# refusal, an authorization refusal, or an unexpected error — stamps
# `finished_at`, so the in-flight lock can never outlive the work. Unexpected
# errors are recorded, reported and then re-raised so the queue shows them.
# The requester always learns the outcome by notification; the header's draft
# pill and Publish button are cleared by the projection that handles the
# `FrameworkVersionPublished` event, whoever published.
class Frameworks::PublishVersionJob < ApplicationJob
  queue_as :default

  # @param publication [FrameworkPublication] the queued request
  # @return [void]
  def perform(publication)
    return unless claim(publication)

    ActsAsTenant.with_tenant(publication.tenant) do
      requester = publication.requested_by
      framework = FrameworkState::Framework.find_by!(framework_id: publication.framework_id)
      unexpected = nil

      begin
        publish(framework, requester)
        publication.update!(status: :succeeded, published_version: framework.reload.current_published_version)
      rescue Pundit::NotAuthorizedError
        publication.update!(status: :failed, error_message: "You no longer have permission to publish this framework.")
      rescue RuntimeError => e
        publication.update!(status: :failed, error_message: e.message)
      rescue StandardError => e
        unexpected = e
        Rails.logger.error("[PublishVersionJob] #{publication.id} #{e.class}: #{e.message}")
        publication.update!(status: :failed, error_message: "Something went wrong while publishing; the error has been logged.")
      ensure
        publication.update_columns(finished_at: Time.current, updated_at: Time.current)
      end

      notify(publication, framework, requester)
      raise unexpected if unexpected
    end
  end

  private

  # Compare-and-set: only the first worker to see the row queued runs it, so a
  # redelivered job cannot publish twice.
  def claim(publication)
    claimed = FrameworkPublication.queued.where(id: publication.id)
      .update_all(status: FrameworkPublication.statuses[:running], started_at: Time.current, job_id: job_id)
    publication.reload if claimed == 1
    claimed == 1
  end

  def publish(framework, requester)
    context = AuthorizationContext.new(user: requester.user, tenant_user: requester, person: requester.person)
    Pundit.authorize(context, framework, :publish?)

    AuditMetadata.with(acting_via: :system, actor_id: requester.person_id&.to_s, correlation_id: job_id) do
      AuditMetadata.wrap_event_store do
        Frameworks::CommandHandler.new.publish_version(framework.framework_id, requester.person_id&.to_s)
      end
    end
  end

  # A notification failure must not mask the outcome already recorded.
  def notify(publication, framework, requester)
    FrameworkPublishedNotifier.with(
      tenant_id: publication.tenant_id,
      framework_id: publication.framework_id,
      framework_name: framework.name,
      version: publication.draft_version,
      succeeded: publication.succeeded?,
      error: publication.error_message
    ).deliver(requester.user)
  rescue StandardError => e
    Rails.logger.error("[PublishVersionJob] notification failed for #{publication.id}: #{e.class}: #{e.message}")
  end
end
