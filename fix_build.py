import re

def main():
    # 1. Update gip_dispatch.zig
    with open("src/gip_dispatch.zig", "r") as f:
        content = f.read()

    # Make helpers public
    helpers = ["writeEscaped", "boundedCount", "getBool", "getInt", "verifierCandidateRequestError", "verifierCandidateExecutionRequestError"]
    for h in helpers:
        content = re.sub(rf"fn {h}\(", f"pub fn {h}(", content)

    # Fix test case calls
    for domain, funcs in [
        ("artifacts", ["dispatchArtifactPatchPropose", "dispatchArtifactAutopsyInspect", "dispatchArtifactRead", "dispatchArtifactList", "dispatchArtifactPolicyDescribe"]),
        ("learning", ["dispatchLearningReview", "dispatchLearningStatus", "dispatchLearningLoopPlan"]),
        ("verification", ["dispatchVerifierList", "dispatchVerifierCandidateExecutionList", "dispatchVerifierCandidateExecutionGet", "dispatchVerifierCandidateProposeFromLearningPlan", "dispatchVerifierCandidateList", "dispatchVerifierCandidateReview", "dispatchVerifierCandidateExecute"])
    ]:
        for fn in funcs:
            content = re.sub(rf"(?<!fn )(?<!pub fn )(?<!\.)\b{fn}\(", f"routes_{domain}.{fn}(", content)

    with open("src/gip_dispatch.zig", "w") as f:
        f.write(content)

    # 2. Add imports to routes_artifacts.zig
    with open("src/gip/routes_artifacts.zig", "r") as f:
        lines = f.readlines()
    
    imports = """const schema = @import("../gip_schema.zig");
const writeEscaped = @import("../gip_dispatch.zig").writeEscaped;
"""
    lines.insert(10, imports)
    with open("src/gip/routes_artifacts.zig", "w") as f:
        f.writelines(lines)

    # 3. Add imports to routes_learning.zig
    with open("src/gip/routes_learning.zig", "r") as f:
        lines = f.readlines()
        
    imports = """const learning_store = @import("../learning_store.zig");
const getBool = @import("../gip_dispatch.zig").getBool;
const getInt = @import("../gip_dispatch.zig").getInt;
"""
    lines.insert(10, imports)
    with open("src/gip/routes_learning.zig", "w") as f:
        f.writelines(lines)

    # 4. Add imports to routes_verification.zig
    with open("src/gip/routes_verification.zig", "r") as f:
        lines = f.readlines()
        
    imports = """const writeEscaped = @import("../gip_dispatch.zig").writeEscaped;
const boundedCount = @import("../gip_dispatch.zig").boundedCount;
const verifierCandidateRequestError = @import("../gip_dispatch.zig").verifierCandidateRequestError;
const verifierCandidateExecutionRequestError = @import("../gip_dispatch.zig").verifierCandidateExecutionRequestError;
"""
    lines.insert(10, imports)
    with open("src/gip/routes_verification.zig", "w") as f:
        f.writelines(lines)

if __name__ == "__main__":
    main()
