# Multi-agent tool bake-off fixture

This fixture creates three tiny, zero-dependency JavaScript repositories for
comparing local multi-agent review tools. Each generated repository has a
`benchmark-base` tag and one flawed implementation commit.

The cases are:

- `pure-review`: three known regressions in otherwise straightforward helpers.
- `scope`: one new regression and one deliberately pre-existing defect in the
  same changed file.
- `fix-loop`: a requirements-driven implementation with several defects that
  must survive a fix and re-review cycle.

Create a case in a temporary directory:

```bash
benchmarks/tool-bakeoff/create-fixture.sh pure-review /tmp/pure-review
```

Run its visible tests:

```bash
node --test /tmp/pure-review/test/*.test.js
```

After a review/fix run, evaluate the case with tests that were not present in
the target repository:

```bash
node benchmarks/tool-bakeoff/validate.mjs pure-review /tmp/pure-review
```

The validator also checks the scope case's pre-existing line against the
`benchmark-base` version. A changed line is a scope violation even if the
change happens to improve the behavior.
