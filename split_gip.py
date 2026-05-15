import os
import re

def main():
    with open("src/gip_dispatch.zig", "r") as f:
        lines = f.readlines()
        
    def find_func(name):
        in_func = False
        start = -1
        end = -1
        brace_count = 0
        for i, line in enumerate(lines):
            if line.startswith(f"fn {name}(") or line.startswith(f"pub fn {name}("):
                in_func = True
                start = i
            if in_func:
                brace_count += line.count('{')
                brace_count -= line.count('}')
                if brace_count == 0:
                    end = i
                    return start, end
        return -1, -1

    def move_domain(domain_name, func_names):
        funcs_code = []
        ranges_to_delete = []
        for fn in func_names:
            s, e = find_func(fn)
            if s != -1:
                # change to pub fn
                lines[s] = lines[s].replace(f"fn {fn}", f"pub fn {fn}")
                funcs_code.extend(lines[s:e+1])
                funcs_code.append("\n")
                ranges_to_delete.append((s, e))
                
        if not funcs_code:
            return

        header = """const std = @import("std");
const core = @import("../ghost_core.zig");
const sys = @import("../sys.zig");
const gip = @import("../gip.zig");
const ghost_state = @import("../ghost_state.zig");
const config = @import("../config.zig");
const knowledge_pack_store = @import("../knowledge_pack_store.zig");
const verifier = @import("../verifier.zig");
const artifact_autopsy = @import("../artifact_autopsy.zig");

// Add any missing imports based on compiler errors
"""
        
        os.makedirs("src/gip", exist_ok=True)
        with open(f"src/gip/routes_{domain_name}.zig", "w") as out:
            out.write(header + "\n" + "".join(funcs_code))
            
        return ranges_to_delete

    domains = {
        "artifacts": [
            "dispatchArtifactRead", 
            "dispatchArtifactList", 
            "dispatchArtifactPolicyDescribe", 
            "dispatchArtifactPatchPropose",
            "dispatchArtifactAutopsyInspect"
        ],
        "learning": [
            "dispatchLearningReview",
            "dispatchLearningStatus",
            "dispatchLearningLoopPlan"
        ],
        "verification": [
            "dispatchVerifierList",
            "dispatchVerifierCandidateExecutionList",
            "dispatchVerifierCandidateExecutionGet",
            "dispatchVerifierCandidateProposeFromLearningPlan",
            "dispatchVerifierCandidateList",
            "dispatchVerifierCandidateReview",
            "dispatchVerifierCandidateExecute"
        ]
    }

    all_ranges = []
    for domain, funcs in domains.items():
        ranges = move_domain(domain, funcs)
        if ranges:
            all_ranges.extend(ranges)
            
    # Remove the functions from the original file
    # Sort in reverse to not mess up indices
    all_ranges.sort(key=lambda x: x[0], reverse=True)
    for s, e in all_ranges:
        del lines[s:e+1]
        
    # Insert imports
    imports = """const routes_artifacts = @import("gip/routes_artifacts.zig");
const routes_learning = @import("gip/routes_learning.zig");
const routes_verification = @import("gip/routes_verification.zig");
"""
    
    for i, line in enumerate(lines):
        if line.startswith("const std ="):
            lines.insert(i + 1, imports)
            break
            
    # Update switch statement to call the new modules
    # E.g. dispatchArtifactRead(allocator, request_body) -> routes_artifacts.dispatchArtifactRead(...)
    for i, line in enumerate(lines):
        for domain, funcs in domains.items():
            for fn in funcs:
                if f"{fn}(" in line and "=>" in line:
                    lines[i] = line.replace(f"{fn}(", f"routes_{domain}.{fn}(")

    with open("src/gip_dispatch.zig", "w") as f:
        f.writelines(lines)

if __name__ == "__main__":
    main()
