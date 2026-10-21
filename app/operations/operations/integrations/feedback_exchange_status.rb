# frozen_string_literal: true

# Where the feedback exchange with a peer system stands for this tenant.
#
# The read half of the exchange's MCP surface. The settings and the signing
# secrets are edited on the Integrations page only, so no secret is ever exposed
# here: only whether each is stored.
class Operations::Integrations::FeedbackExchangeStatus < Operations::Base
  description "Show the state of this workspace's feedback exchange with a peer system: whether it is " \
              "set up (connected means enabled with a peer and both signing secrets stored; it does not " \
              "prove the peer answers), the peer and its address, the last sync, the types it sends and imports " \
              "(an empty import list means everything), whether the secrets and sync cursors are present, and " \
              "what the import has done: records imported, updated, withdrawn and skipped, with each skip reason " \
              "and the people the peer named that GrowthOS could not find. Never returns a secret."
  category :read
  approval :none

  def policy_check
    authorize :integrations, :show?
  end

  # @return [Hash]
  def perform
    tenant = ActsAsTenant.current_tenant
    config = tenant.feedback_exchange_config
    secrets = tenant.feedback_exchange_secrets

    {
      state: config.state(secrets_complete: secrets.complete?),
      connected: config.configured?(tenant),
      enabled: config.enabled?,
      peer: config.peer_name,
      peer_address: config.base_url,
      last_synced_at: config.last_synced_at&.iso8601,
      secrets: { outbound: secrets.outbound_secret.present?, inbound: secrets.inbound_secret.present? },
      cursors: { feedback: config.cursor.present?, deletions: config.deletions_cursor.present? },
      export_kinds: config.export_kinds,
      import_kinds: config.import_kinds,
      imports: FeedbackExchangeImport.summary,
      unmatched_people: FeedbackExchangeImport.unmatched_people
    }
  end
end
