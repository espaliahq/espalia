# frozen_string_literal: true

# Requests publication of the current draft as a new framework version.
#
# Publishing is irreversible and heavy: it rebuilds the published
# projection, fires cross-stream assessment migrations (one
# `FrameworkVersionMigrated` per affected person) and rolls every open
# assessment cycle's version range forward — far too much for a request. So
# this operation only *requests* it: it checks the publish gate up front,
# records a {FrameworkPublication} and enqueues {Frameworks::PublishVersionJob},
# which does the work as the requester and reports back by notification.
#
# Routes to :in_app approval — an MCP agent hands off to the web for the
# owner/editor to confirm; the review page's confirm button dispatches this
# directly. Both surfaces therefore share the in-flight lock (one unfinished
# request per framework, enforced by a partial unique index) and the
# "Publishing…" state it drives.
#
# Refusals — no draft, a retiring capability without a migration mapping, a
# publish already in flight — surface as RuntimeError with user-facing copy.
class Operations::Frameworks::PublishVersion < Operations::Base
  description "Request publication of the current draft as a new framework version; " \
              "runs in the background and notifies the requester (owner/editor only)."
  category :write
  approval :in_app

  parameter :framework_id, String, required: true

  def policy_check
    authorize framework, :publish?
  end

  # @return [Hash] { framework_id:, publication_id:, draft_version:, status: "queued" }
  # @raise [RuntimeError] when the draft cannot be published as it stands
  def perform
    raise "No draft in progress." unless framework.draft?
    raise "Publishing needs a membership in this tenant." if context.tenant_user.nil?

    unmapped = Frameworks::RetiringCapabilitiesQuery.new(framework).unmapped_names
    raise "Add a migration mapping before publishing: #{unmapped.to_sentence}." if unmapped.any?

    FrameworkPublication.reap_stale!(framework.framework_id)
    publication = FrameworkPublication.create!(
      tenant: framework.tenant,
      framework_id: framework.framework_id,
      draft_version: framework.draft_version,
      requested_by: context.tenant_user
    )
    Frameworks::PublishVersionJob.perform_later(publication)

    {
      framework_id: framework.framework_id,
      publication_id: publication.id,
      draft_version: framework.draft_version,
      status: "queued"
    }
  rescue ActiveRecord::RecordNotUnique
    raise "v#{framework.draft_version} is already being published."
  end

  private

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
