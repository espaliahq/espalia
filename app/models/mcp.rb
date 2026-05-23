# frozen_string_literal: true

# Namespace for MCP-specific persistence models. Used today for the
# Doorkeeper model subclasses (Mcp::Application, Mcp::AccessGrant,
# Mcp::AccessToken) so OAuth records get UUID v7 ids via
# ApplicationRecord's before_create callback. Future MCP-only models
# (e.g. PendingMcpApproval) will land here too.
module Mcp
end
