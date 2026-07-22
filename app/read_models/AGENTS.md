Read the following guidelines before working in this directory:

@../../docs/guidelines/event-sourcing.md
@../../docs/guidelines/rails-models.md

**Read-model ownership rule:** every table in this directory has exactly one
projection writer. If two contexts need overlapping data, model it as two
tables joined at read time (e.g. via a value-object wrapper) — never as a
shared row. See the anti-pattern entry in `docs/guidelines/event-sourcing.md`.
