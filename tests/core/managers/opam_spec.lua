local match = require "luassert.match"
local mock = require "luassert.mock"
local Optional = require "mason.core.optional"
local installer = require "mason.core.installer"
local opam = require "mason.core.managers.opam"

describe("opam manager", function()
    it(
        "should call opam install",
        async_test(function()
            local handle = InstallHandleGenerator "dummy"
            local ctx = InstallContextGenerator(handle, { requested_version = "42.13.37" })
            installer.run_installer(ctx, opam.packages { "main-package", "supporting-package", "supporting-package2" })
            assert.spy(ctx.spawn.opam).was_called(1)
            assert.spy(ctx.spawn.opam).was_called_with(match.tbl_containing {
                "install",
                "--destdir=.",
                "--yes",
                "--verbose",
                match.tbl_containing {
                    "main-package.42.13.37",
                    "supporting-package",
                    "supporting-package2",
                },
            })
        end)
    )

    it(
        "should provide receipt information",
        async_test(function()
            local handle = InstallHandleGenerator "dummy"
            local ctx = InstallContextGenerator(handle, { requested_version = "42.13.37" })
            installer.run_installer(ctx, opam.packages { "main-package", "supporting-package", "supporting-package2" })
            assert.same({
                type = "opam",
                package = "main-package",
            }, ctx.receipt.primary_source)
            assert.same({
                {
                    type = "opam",
                    package = "supporting-package",
                },
                {
                    type = "opam",
                    package = "supporting-package2",
                },
            }, ctx.receipt.secondary_sources)
        end)
    )
end)
