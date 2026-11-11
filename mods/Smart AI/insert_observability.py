#!/usr/bin/env python3
"""Insert unit observation and audit heartbeat functions after logTargetEval."""

import sys

with open('D:\\Games\\Red Alert 2 LuaAPI\\mods\\Smart AI\\main.lua', 'r') as f:
    content = f.read()

# Find the end of SmartAI.logTargetEval function (last "return ok")
target_eval_start = content.find('SmartAI.logTargetEval = function')
if target_eval_start < 0:
    print("ERROR: Could not find logTargetEval function start", file=sys.stderr)
    sys.exit(1)

# Find "return ok" after the function start
return_ok_pos = content.find('    return ok\n', target_eval_start)
if return_ok_pos < 0:
    print("ERROR: Could not find 'return ok' after logTargetEval", file=sys.stderr)
    sys.exit(1)

return_ok_pos += len('    return ok\n')

# The unit observation and heartbeat functions to insert
unit_obs_heartbeat = '''


-- ---------------------------------------------------------------------------
-- Unit observation (observability upgrade).
-- Records relevant unit state so a log reader can correlate game behavior
-- with SmartAI decisions. Logs only on state changes to avoid frame-spam.
-- Observed unit types: Kirov, aircraft, helicopters, naval units,
-- DEFENSE/RAID/FEINT/RETARGET/MARCH_RECALL/WAVE_RECALL units.
-- ---------------------------------------------------------------------------
SmartAI.logUnitObservation = function(unit_id, unit_type, house,
    x, y, current_target, attack_state, classification, managed)
    local ok = pcall(function()
        local body = string.format(
            "unit_id=%s unit_type=%s house=%s x=%s y=%s ",
            tostring(unit_id), tostring(unit_type), tostring(house or "-"),
            tostring(x or "-"), tostring(y or "-"))
        if current_target then
            body = body .. string.format(
                "current_target_id=%s current_target_type=%s ",
                tostring(current_target.id), tostring(current_target.t))
        end
        if attack_state ~= nil then
            body = body .. string.format(
                "attack_state=%s ", tostring(attack_state))
        end
        if classification then
            body = body .. string.format(
                "classification=%s ", tostring(classification))
        end
        if managed ~= nil then
            body = body .. string.format(
                "managed=%s ", tostring(managed))
        end
        dlog("UNIT_OBSERVATION", SmartAI.prov.frame, body)
    end)
    return ok
end


-- ---------------------------------------------------------------------------
-- Audit heartbeat and coverage (observability upgrade).
-- Reports which SmartAI subsystems executed during the current tick so a
-- log reader can establish command-path coverage intervals. Does not report
-- COMPLETE if any relevant subsystem is uninstrumented or did not execute.
-- ---------------------------------------------------------------------------
SmartAI.logAuditHeartbeat = function(house,
    commander_status, officer_status,
    target_evaluation_status,
    command_issuance_status, commands_issued,
    rejected_decisions, logging_errors)
    local ok = pcall(function()
        local body = string.format(
            "house=%s commander_status=%s officer_status=%s ",
            tostring(house or "-"), tostring(commander_status or "-"),
            tostring(officer_status or "-"))
        if target_evaluation_status then
            body = body .. string.format(
                "target_evaluation_status=%s ", tostring(target_evaluation_status))
        end
        if command_issuance_status then
            body = body .. string.format(
                "command_issuance_status=%s ", tostring(command_issuance_status))
        end
        if commands_issued ~= nil then
            body = body .. string.format(
                "commands_issued=%s ", tostring(commands_issued))
        end
        if rejected_decisions ~= nil then
            body = body .. string.format(
                "rejected_decisions=%s ", tostring(rejected_decisions))
        end
        if logging_errors ~= nil then
            body = body .. string.format(
                "logging_errors=%s ", tostring(logging_errors))
        end
        dlog("SMARTAI_AUDIT_HEARTBEAT", SmartAI.prov.frame, body)
    end)
    return ok
end'''

new_content = content[:return_ok_pos] + unit_obs_heartbeat + content[return_ok_pos:]

with open('D:\\Games\\Red Alert 2 LuaAPI\\mods\\Smart AI\\main.lua', 'w') as f:
    f.write(new_content)

print("Insertion successful")