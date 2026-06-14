# frozen_string_literal: true

# Publishes the current draft as a new framework version.
#
# Irreversible and high-impact: publishing rebuilds the published
# projection, fires cross-stream assessment migrations
# (FrameworkVersionMigrated per affected person), and rolls every open
# assessment cycle's version range forward. It therefore routes to
# :in_app approval — an MCP agent must hand off to the web UI for the
# owner/editor to confirm; the web controller (the in-app surface itself)
# runs it directly behind a Turbo confirm dialog.
#
# The aggregate enforces the publish gate: it raises if no draft is in
# progress, or if any capability archived during the draft (and present
# before it started) lacks a migration mapping (ADR-17). Those surface as
# RuntimeError to the caller.
class Operations::Frameworks::PublishVersion < Operations::Base
  description "Publish the current draft as a new framework version (owner/editor only)."
  category :write
  approval :in_app

  parameter :framework_id, String, required: true

  def policy_check
    authorize framework, :publish?
  end

  # @return [Hash] { framework_id:, published_version: } — the version the
  #   framework now sits at after the draft was published.
  def perform
    Frameworks::CommandHandler.new.publish_version(
      framework.framework_id, context.person&.id&.to_s
    )
    {
      framework_id: framework.framework_id,
      published_version: framework.reload.current_published_version
    }
  end

  private

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
