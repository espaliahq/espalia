# Integration Architecture

> Read this when: working on HRIS sync, notification adapters, SSO/SAML, or any external system integration.

---

## HRIS Sync

Pluggable adapter interface. Implementations for HiBob, BambooHR, etc.

```ruby
# app/integrations/hris/base_adapter.rb
module Integrations::Hris
  class BaseAdapter
    def sync_people(tenant)
      raise NotImplementedError
    end
  end
end
```

Creates/updates Person records. Maps external role titles → Framework roles/levels via configurable mapping in `Tenant.hris_config`. Does NOT create User records — invitation is a separate flow.

---

## Notifications

RES async handlers dispatched via Solid Queue. Adapter pattern for Slack, Teams, email.

```ruby
# app/contexts/person_development/async_handlers/assessment_notifier.rb
class PersonDevelopment::AsyncHandlers::AssessmentNotifier < ApplicationJob
  prepend RailsEventStore::AsyncHandler

  def perform(event)
    ActsAsTenant.with_tenant(Tenant.find(event.metadata[:tenant_id])) do
      case event
      when PersonDevelopment::Events::SelfRated
        notify_manager_of_self_assessment(event)
      when PersonDevelopment::Events::FullAlignmentCompleted
        notify_person_of_alignment_complete(event)
      end
    end
  end
end
```

---

## SSO/SAML

Devise + OmniAuth. Tenant-level SSO config stored in `Tenant.sso_config`. Self-hosted mode supports local username/password. SaaS mode routes to tenant-specific IdP.
