Each layer under `app/` imports its own guide from its `AGENTS.md`, so nothing is imported here: an import in this file would load into every session that opens any file under `app/`.

Directories with no guide of their own follow the closest one:

- `queries/`, `jobs/` — [rails-models.md](../docs/guidelines/rails-models.md); a query over ratings also needs [assessments/role-lens.md → Role-scoped reads](../docs/guidelines/assessments/role-lens.md)
- `notifiers/` — [slack-integration.md](../docs/guidelines/slack-integration.md) for delivery
- `helpers/`, `mailers/` — [phlex-views.md](../docs/guidelines/phlex-views.md)
