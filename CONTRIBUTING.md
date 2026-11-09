# Contributing

Run `ruby test/test_*.rb` for each file, or `rake test`. Generator tests run on CRuby;
`ruby scripts/verify_runtime.rb` additionally checks the generated Ruby with Spinel when present.
Runtime packages use `spin test`. CI pins both a release and a reference master commit.
Include a failing input and expected behavior for bug fixes. Do not refresh snapshots to
hide a CRuby/Spinel difference. Document public API changes in README and CHANGELOG.
