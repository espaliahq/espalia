# frozen_string_literal: true

# Extend Noticed's own model (which inherits the gem's ApplicationRecord, not
# ours) with the in-app inbox behaviour. Using the documented load hook keeps
# the extension out of the gem and lets Zeitwerk own NotificationInbox.
ActiveSupport.on_load(:noticed_notification) do
  include NotificationInbox
end
