--!A cross-platform build utility based on Lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Copyright (C) 2015-present, Xmake Open Source Community.
--
-- @author      ruki, MeanSquaredError
-- @file        parse_legacy.lua
--

-- imports
import("core.base.option")
import("core.project.target")

-- exclude cmake internal definitions https://github.com/xmake-io/xmake/issues/5217
function _should_exclude(define)
    local name = define:split("=")[1]
    return table.contains({"CMAKE_INTDIR", "_DEBUG", "NDEBUG"}, name)
end

function _parse_makefiles_flags_make(opt)
    local flagsfile = path.join(opt.work_dir, "CMakeFiles", opt.exe_name .. ".dir", "flags.make")
    if not os.isfile(flagsfile) then
        return nil
    end
    local flagsdata = io.readfile(flagsfile)
    if not flagsdata then
        return nil
    end
    if option.get("diagnosis") then
        cprint("finding includes from %s", flagsfile)
        io.write(flagsdata .. "\n")
    end
    local defines = {}
    local includedirs = {}
    for _, line in ipairs(flagsdata:split("\n", {plain = true})) do
        if line:find("CXX_INCLUDES =", 1, true) then
            local has_include = false
            local flags = os.argv(line:split("=", {plain = true})[2]:trim())
            for _, flag in ipairs(flags) do
                if has_include or (flag:startswith("-I") and #flag > 2) then
                    local includedir = has_include and flag or flag:sub(3)
                    if includedir and os.isdir(includedir) then
                        table.insert(includedirs, includedir)
                    end
                    has_include = false
                elseif flag == "-isystem" or flag == "-I" then
                    has_include = true
                end
            end
        elseif line:find("CXX_DEFINES =", 1, true) then
            local flags = os.argv(line:split("=", {plain = true})[2]:trim())
            for _, flag in ipairs(flags) do
                if flag:startswith("-D") and #flag > 2 then
                    local define = flag:sub(3)
                    if define and not _should_exclude(define) then
                        table.insert(defines, define)
                    end
                end
            end
        end
    end
    return {
        defines = defines,
        includedirs = includedirs
    }
end

function _is_library(line)
    for _, suffix in ipairs({".so", ".dylib", ".tbd", ".lib"}) do
        if line:find(suffix, 1, true) then
            return true
        end
    end
    return false
end

function _parse_makefiles_links(opt)
    local linkfile = path.join(opt.work_dir, "CMakeFiles", opt.exe_name .. ".dir", "link.txt")
    if not os.isfile(linkfile) then
        return nil
    end
    local linkdata = io.readfile(linkfile)
    if not linkdata then
        return nil
    end
    if option.get("diagnosis") then
        cprint("finding links from %s", linkfile)
        io.write(linkdata .. "\n")
    end
    local links = {}
    local linkdirs = {}
    local libfiles = {}
    local ldflags = {}
    for _, line in ipairs(os.argv(linkdata)) do
        if line:startswith("-Wl,") then
            table.insert(ldflags, line)
        elseif _is_library(line) then
            -- strip library version suffix, e.g. libxxx.so.1.1 -> libxxx.so
            if line:find(".so", 1, true) then
                line = line:gsub("lib(.-)%.so%..+$", "lib%1.so")
            end

            -- get libfiles
            if os.isfile(line) then
                table.insert(libfiles, line)
            end

            -- get links and linkdirs
            local linkdir = path.directory(line)
            if linkdir ~= "." then
                table.insert(linkdirs, linkdir)
            end
            local link = target.linkname(path.filename(line))
            if link then
                table.insert(links, link)
            end
        elseif line:startswith("-l") then
            -- is link, e.g. -lxxx
            local link = line:sub(3):trim()
            table.insert(links, link)
        end
    end
    return {
        links = links,
        linkdirs = linkdirs,
        libfiles = libfiles,
        ldflags = ldflags
    }
end

function _parse_makefiles(opt)
    local parsed_flags_make = _parse_makefiles_flags_make(opt)
    if not parsed_flags_make then
        return nil
    end
    local parsed_links = _parse_makefiles_links(opt)
    if not parsed_links then
        return nil
    end
    return table.join(parsed_flags_make, parsed_links)
end

function _parse_visual_studio(opt)
    local vcprojfile = path.join(opt.work_dir, opt.exe_name .. ".vcxproj")
    if not os.isfile(vcprojfile) then
        return nil
    end
    local vcprojdata = io.readfile(vcprojfile)
    vcprojdata = vcprojdata:match("<ItemDefinitionGroup Condition=\"'$%(Configuration%)|$%(Platform%)'=='" .. opt.envs.CMAKE_BUILD_TYPE .. "|.->(.-)</ItemDefinitionGroup>")
    if not vcprojdata then
        return nil
    end

    local links = {}
    local linkdirs = {}
    local defines = {}
    local libfiles = {}
    local includedirs = {}
    for _, line in ipairs(vcprojdata:split("\n", {plain = true})) do
        local values = line:match("<AdditionalIncludeDirectories>(.+);%%%(AdditionalIncludeDirectories%)</AdditionalIncludeDirectories>")
        if values then
            table.join2(includedirs, path.splitenv(values))
        end

        values = line:match("<AdditionalDependencies>(.+)</AdditionalDependencies>")
        if values then
            for _, library in ipairs(path.splitenv(values)) do
                -- get libfiles
                if os.isfile(library) then
                    table.insert(libfiles, library)
                end

                -- get links and linkdirs
                local linkdir = path.directory(library)
                linkdir = path.translate(linkdir)
                if linkdir ~= "." and not linkdir:startswith(opt.work_dir) then
                    table.insert(linkdirs, linkdir)
                    local link = target.linkname(path.filename(library))
                    if link then
                        table.insert(links, link)
                    end
                end
            end
        end

        values = line:match("<PreprocessorDefinitions>%%%(PreprocessorDefinitions%);(.+)</PreprocessorDefinitions>")
        if values then
            values = path.splitenv(values)
            for _, value in ipairs(values) do
                if not _should_exclude(value) then
                    table.insert(defines, value)
                end
            end
        end
    end
    return {
        links = links,
        linkdirs = linkdirs,
        defines = defines,
        libfiles = libfiles,
        includedirs = includedirs
    }
end

function main(opt)
    return
        _parse_makefiles(opt) or
        _parse_visual_studio(opt)
end
