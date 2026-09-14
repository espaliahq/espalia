# frozen_string_literal: true

# Publishes a framework draft in the background.
#
# Publishing rebuilds the published projection and then, in the same
# transaction, migrates every assigned person's ratings, evidence and comments
# onto the new version (`FrameworkVersionMigrationSync`) — one PersonDev stream
# replay per person. For a real framework that is far too slow for a web
# request, so the controller records a {FrameworkPublication} and enqueues this
# job; the record is what the UI reads to show "Publishing…" and to refuse a
# second request while this one runs.
#
# Runs {Operations::Frameworks::PublishVersion} with the requester's own
# authorization context, rebuilt from their TenantUser, so a publish right
# revoked between request and run is refused rather than honoured. Every
# outcome is written back to the record and delivered to the requester as a
# notification; a success also clears the header's draft pill and Publish
# button on any open explorer page.
class Frameworks::PublishVersionJob < ApplicationJob
  queue_as :default

  # Domain refusals (publish gate, no draft) and authorization failures are
  # outcomes to report, not bugs to retry.
  REPORTED_FAILURES = [ RuntimeError, Pundit::NotAuthorizedError ].freeze

  # @param publication [FrameworkPublication] the queued request
  # @return [void]
  def perform(publication)
    return unless publication.queued?

    publication.update!(status: :running, started_at: Time.current, job_id: job_id)

    ActsAsTenant.with_tenant(publication.tenant) do
      requester = publication.requested_by
      AuditMetadata.with(acting_via: :system, actor_id: requester.person_id&.to_s, correlation_id: job_id) do
        result = Operations::Frameworks::PublishVersion.call(
          context: AuthorizationContext.new(
            user: requester.user, tenant_user: requester, person: requester.person
          ),
          params: { framework_id: publication.framework_id }
        )
        publication.update!(status: :succeeded, published_version: result[:published_version],
                            finished_at: Time.current)
      rescue *REPORTED_FAILURES => e
        publication.update!(status: :failed, error_message: e.message, finished_at: Time.current)
      end

      notify(publication)
      clear_draft_status(publication) if publication.succeeded?
    end
  end

  private

  def notify(publication)
    framework = FrameworkState::Framework.find_by(framework_id: publication.framework_id)
    FrameworkPublishedNotifier.with(
      tenant_id: publication.tenant_id,
      framework_id: publication.framework_id,
      framework_name: framework&.name || "Framework",
      version: publication.draft_version,
      succeeded: publication.succeeded?,
      error: publication.error_message
    ).deliver(publication.requested_by.user)
  end

  # The draft pill and Publish button sit outside every Turbo Frame, so an
  # explorer page left open during the publish would keep offering a draft
  # that no longer exists. With no draft both slots render empty for every
  # viewer, so broadcasting them as visible reveals nothing.
  def clear_draft_status(publication)
    framework = FrameworkState::Framework.find_by(framework_id: publication.framework_id)
    return unless framework

    { badge: Views::Frameworks::Explorer::DraftStatus::BADGE_ID,
      publish: Views::Frameworks::Explorer::DraftStatus::PUBLISH_ID }.each do |slot, target|
      Turbo::StreamsChannel.broadcast_replace_to(
        "framework_activity", publication.framework_id,
        target: target,
        html: ApplicationController.render(
          Views::Frameworks::Explorer::DraftStatus.new(framework: framework, slot: slot, visible: true),
          layout: false
        )
      )
    end
  rescue => e
    Rails.logger.warn("[PublishVersionJob] draft status broadcast failed: #{e.message}")
  end
end
