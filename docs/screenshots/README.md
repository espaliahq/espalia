# README screenshots

The images the top-level [README](../../README.md) shows. A system test takes
them all from the seeded demo tenant:

```bash
README_SCREENSHOTS=1 bin/rails test test/system/marketing_flows_system_test.rb
```

[`marketing_flows_system_test.rb`](../../test/system/marketing_flows_system_test.rb)
runs in every suite, so a flow that stops rendering fails CI. Without
`README_SCREENSHOTS=1` it writes to `tmp/screenshots/readme/` and leaves
these files alone. Only the flag overwrites them. Commit the results.

- **Install `pngquant` first.** The test quantises each capture with it, taking
  it from about 380 KB to about 100 KB. Without it the test warns and writes
  the full-size file.
- **To add a screen,** add a `capture_*` step to the test and an image to the
  README. The test signs in as the right person, sets the 1440×900 @2x
  viewport and the README's Custom theme for you.
- **Regenerate in the PR that changes a screen,** and commit only that
  screen's image. When a refresh is due:
  [issue-delivery.md → Ground rules](../guidelines/issue-delivery.md#ground-rules),
  *Refresh the README screenshots your change makes stale*.
- **Expect pixel churn.** Times ("1s ago"), ratings and which capability a
  piece of feedback lands on change from run to run, so every regeneration
  rewrites every file. Regenerate when the screens change, not routinely.
