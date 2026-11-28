# frozen_string_literal: true

# Persisted handoff for high-stakes MCP operations that require in-app
# confirmation (publish version, close cycle, change collaborator role,
# etc — anything an Operation declares `approval :in_app`). The MCP
# server creates one of these in response to a tools/call, returns the
# review URL to the client, and the user resolves it from the web UI.
#
# `arguments` is the same hash the MCP client originally submitted; it's
# replayed verbatim into `operation_class.call(context:, params:)` when
# the user clicks Approve. `result_payload` captures whatever the
# Operation returned so the user can see the outcome immediately, and
# (future) the MCP client can fetch it via a polling tool.
class Mcp::PendingApproval < ApplicationRecord
  # Rails' default inflection drops the Mcp:: namespace and looks for
  # `pending_approvals`; the migration uses `mcp_pending_approvals` to
  # match the rest of the Mcp:: ActiveRecord models.
  self.table_name = "mcp_pending_approvals"

  # Belt-and-braces tenant scoping. The controller uses
  # `ActsAsTenant.without_tenant` to look up an approval by its secret id
  # (which may be opened in a browser session bound to a different
  # tenant). Declaring acts_as_tenant means any future read path that
  # forgets the explicit `without_tenant` will still be scoped, never
  # silently leaking cross-tenant.
  acts_as_tenant :tenant

  belongs_to :user
  belongs_to :client_application, class_name: "Mcp::Application"

  EXPIRY_WINDOW = 24.hours

  before_create :refuse_an_approval_after_replaced_credentials

  enum :status, { pending: 0, approved: 1, rejected: 2, expired: 3 }

  validates :operation_class, presence: true
  validates :expires_at, presence: true
  # `arguments` is a jsonb column defaulting to `{}` — an empty hash is
  # legitimate (an Operation with no parameters). Don't require presence.

  scope :open,    -> { where(status: :pending).where("expires_at > ?", Time.current) }
  scope :stale,   -> { where(status: :pending).where("expires_at <= ?", Time.current) }

  # @return [Class<Operations::Base>]
  def operation
    operation_class.constantize
  end

  # @return [Boolean]
  def resolvable?
    pending? && expires_at > Time.current
  end

  private

  # An MCP call is authenticated before it stores its approval, so a credential
  # change such as User#replace_credentials! or a password reset can revoke the
  # call's token in between, or the token can expire. Under the lock those take,
  # the token must still be live. Any revocation stamp counts, as another
  # process's clock may run ahead of this one. With no token set it refuses, so
  # any new path that stores an approval must set Mcp::RequestCredentials first,
  # as Mcp::ServerController does today.
  def refuse_an_approval_after_replaced_credentials
    User.lock(User::CREDENTIALS_LOCK).find_by(id: user_id)
    token_id = Mcp::RequestCredentials.access_token_id
    # Uncached, so a read earlier in the request can't answer for the row after the lock.
    token = ActiveRecord::Base.uncached { Mcp::AccessToken.find_by(id: token_id, resource_owner_id: user_id, revoked_at: nil) } if token_id
    raise Mcp::RequestCredentials::Replaced if token.nil? || token.expired?
  end
end
