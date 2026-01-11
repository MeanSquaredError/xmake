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
-- Copyright (C) 2026-present, Xmake Open Source Community.
--
-- @author      MeanSquaredError
-- @file        parse_file_api.lua
--

-- imports
import("core.base.json")
import("core.base.option")

function _load_reply_file(reply_dir, reply_file)
    local reply_path = path.join(reply_dir, reply_file)
    local reply_str = io.readfile(reply_path)
    if option.get("diagnosis") then
        cprint("parsing cmake-file-api reply file %s", reply_path)
        io.write(reply_str .. "\n")
    end
    return json.decode(reply_str)
end

function _load_index_file(reply_dir)
    local index_pattern = path.join(reply_dir, "index-*.json")
    local index_files = os.files(index_pattern)
    if #index_files ~= 1 then
        return nil
    end
    local index_path = index_files[1]
    local index_str = io.readfile(index_path)
    if option.get("diagnosis") then
        cprint("parsing cmake-file-api reply index %s", index_path)
        io.write(index_str .. "\n")
    end
    return json.decode(index_str)
end

function _load_target_file(targets, target_name, reply_dir)
    local idx = table.find_first_if(targets, function(_, t) return t.name == target_name end)
    return idx and _load_reply_file(reply_dir, targets[idx].jsonFile)
end

function _find_config(codemodel, config_name)
    local idx = table.find_first_if(codemodel.configurations, function(_, cfg) return cfg.name == config_name end)
    return idx and codemodel.configurations[idx]
end

function _parse_exe_target(config, exe_name, reply_dir)
    local exe_target = _load_target_file(config.targets, exe_name, reply_dir)
    if not exe_target then
        return nil
    end
    local compile_group = exe_target.compileGroups[1]
    return {
        defines = table.imap(compile_group.defines, function(_, v) return v.define end),
        includedirs = table.imap(compile_group.includes, function(_, v) return v.path end),
        links = {},
        ldflags = {},
        linkdirs = {},
        libfiles = {},
    }
end

function main(opt)
    local reply_dir = path.join(opt.work_dir, ".cmake", "api", "v1", "reply")
    local index = _load_index_file(reply_dir)
    local codemodel = _load_reply_file(reply_dir, index.reply["codemodel-v2"].jsonFile)
    local config = _find_config(codemodel, opt.envs.CMAKE_BUILD_TYPE)
    if not config then
        return nil
    end
    return _parse_exe_target(config, opt.exe_name, reply_dir)
end
