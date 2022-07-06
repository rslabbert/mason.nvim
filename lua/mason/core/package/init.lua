local a = require "mason.core.async"
local _ = require "mason.core.functional"
local installer = require "mason.core.installer"
local InstallationHandle = require "mason.core.installer.handle"
local Optional = require "mason.core.optional"
local log = require "mason.log"
local EventEmitter = require "mason.core.EventEmitter"
local indexer = require "mason.core.package.indexer"
local receipt = require "mason.core.receipt"
local fs = require "mason.core.fs"
local path = require "mason.core.path"
local linker = require "mason.core.installer.linker"

local version_checks = require "mason.core.package.version-check"

---@class Package : EventEmitter
---@field name string
---@field spec PackageSpec
---@field private handle InstallHandle @The currently associated handle.
local Package = setmetatable({}, { __index = EventEmitter })

---@param package_identifier string
---@return string, string | nil
Package.Parse = function(package_identifier)
    local name, version = unpack(vim.split(package_identifier, "@"))
    return name, version
end

---@alias PackageLanguage string

---@type table<PackageLanguage, PackageLanguage>
Package.Lang = setmetatable({}, {
    __index = function(s, lang)
        s[lang] = lang
        return s[lang]
    end,
})

---@class PackageCategory
Package.Cat = {
    Compiler = "Compiler",
    Runtime = "Runtime",
    DAP = "DAP",
    LSP = "LSP",
    Linter = "Linter",
    Formatter = "Formatter",
}

local PackageMt = { __index = Package }

---@class PackageSpec
---@field name string
---@field desc string
---@field homepage string
---@field categories PackageCategory[]
---@field languages PackageLanguage[]
---@field install async fun(ctx: InstallContext)

---@param spec PackageSpec
function Package.new(spec)
    vim.validate {
        name = { spec.name, "s" },
        desc = { spec.desc, "s" },
        homepage = { spec.homepage, "s" },
        categories = { spec.categories, "t" },
        languages = { spec.languages, "t" },
        install = { spec.install, "f" },
    }

    return EventEmitter.init(setmetatable({
        name = spec.name, -- for convenient access
        spec = spec,
    }, PackageMt))
end

function Package:new_handle()
    self:get_handle():if_present(function(handle)
        assert(handle:is_closed(), "Cannot create new handle because existing handle is not closed.")
    end)
    log.fmt_trace("Creating new handle for %s", self)
    local handle = InstallationHandle.new(self)
    self.handle = handle
    self:emit("handle", handle)
    return handle
end

---@param opts { version: string|nil } | nil
---@return InstallHandle
function Package:install(opts)
    opts = opts or {}
    return self
        :get_handle()
        :map(function(handle)
            if not handle:is_closed() then
                log.fmt_debug("Handle %s already exist for package %s", handle, self)
                return handle
            end
        end)
        :or_else_get(function()
            local handle = self:new_handle()
            -- This function is not expected to be run in async scope, so we create
            -- a new scope here and handle the result callback-style.
            a.run(
                installer.execute,
                ---@param success boolean
                ---@param result Result
                function(success, result)
                    if not success then
                        log.error("Unexpected error", result)
                        self:emit("install:failed", handle)
                        return
                    end
                    result
                        :on_success(function()
                            self:emit("install:success", handle)
                            indexer:emit("package:install:success", self, handle)
                        end)
                        :on_failure(function()
                            self:emit("install:failed", handle)
                            indexer:emit("package:install:failed", self, handle)
                        end)
                end,
                handle,
                {
                    requested_version = opts.version,
                }
            )
            return handle
        end)
end

function Package:uninstall()
    local was_unlinked = self:unlink()
    if was_unlinked then
        self:emit "uninstall:success"
    end
    return was_unlinked
end

function Package:unlink()
    log.fmt_info("Unlinking %s", self)
    local install_path = self:get_install_path()
    -- 1. Unlink
    self:get_receipt():map(_.prop "links"):if_present(function(links)
        linker.unlink(self, links)
    end)

    -- 2. Remove installation artifacts
    if fs.sync.dir_exists(install_path) then
        fs.sync.rmrf(install_path)
        return true
    end
    return false
end

function Package:is_installed()
    return indexer.is_installed(self.name)
end

function Package:get_handle()
    return Optional.of_nilable(self.handle)
end

function Package:get_install_path()
    return path.package_prefix(self.name)
end

---@return Optional @Optional<@see InstallReceipt>
function Package:get_receipt()
    local receipt_path = path.concat { self:get_install_path(), "mason-receipt.json" }
    if fs.sync.file_exists(receipt_path) then
        return Optional.of(receipt.InstallReceipt.from_json(vim.json.decode(fs.sync.read_file(receipt_path))))
    end
    return Optional.empty()
end

---@param callback fun(success: boolean, version_or_err: string)
function Package:get_installed_version(callback)
    a.run(function()
        local receipt = self:get_receipt():or_else_throw "Unable to get receipt."
        return version_checks.get_installed_version(receipt, self:get_install_path()):get_or_throw()
    end, callback)
end

---@param callback fun(success: boolean, result_or_err: NewPackageVersion)
function Package:check_new_version(callback)
    a.run(function()
        local receipt = self:get_receipt():or_else_throw "Unable to get receipt."
        return version_checks.get_new_version(receipt, self:get_install_path()):get_or_throw()
    end, callback)
end

function Package:get_lsp_settings_schema()
    local ok, schema = pcall(require, ("mason._generated.lsp-schemas.%s"):format(self.name))
    if not ok then
        return Optional.empty()
    end
    return Optional.of(schema)
end

function PackageMt.__tostring(self)
    return ("Package(name=%s)"):format(self.name)
end

return Package
