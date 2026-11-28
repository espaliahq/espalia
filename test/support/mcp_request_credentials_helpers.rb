# frozen_string_literal: true

# Stores MCP grants and approvals as an authenticated request would, so the
# credential checks their models make before saving pass.
module McpRequestCredentialsHelpers
  def as_consent_by(user, &)
    Mcp::RequestCredentials.set(session_salt: user.authenticatable_salt, &)
  end

  def as_mcp_call_by(user, application, tenant:, &)
    token = Mcp::AccessToken.create!(application:, resource_owner_id: user.id, tenant_id: tenant.id, scopes: "read", expires_in: 3600)
    as_mcp_call_with(token, &)
  end

  def as_mcp_call_with(token, &)
    Mcp::RequestCredentials.set(access_token_id: token.id, &)
  end
end
