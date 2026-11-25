# Integration tests

Run `make integration-test` to start and check the local services. See the
[integration testing guide](../../docs/integration-testing.md) for dependency
setup.

Each file in `fixtures/` defines one ERT test. Use
`omnigent-integration-with-run` once in each test to start an isolated
environment and clean up its resources. The macro and its helpers are in
`omnigent-integration-fixture.el`.

Run `make unit-test` to run the tests in `test/unit/`. That suite includes
checks for the setup and cleanup helpers.
