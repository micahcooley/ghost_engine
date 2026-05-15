import sys
import re
import os

with open("src/gip_dispatch.zig", "r") as f:
    lines = f.readlines()

def extract_function(func_name, lines):
    in_func = False
    func_lines = []
    brace_count = 0
    start_idx = -1
    end_idx = -1
    
    for i, line in enumerate(lines):
        if line.startswith(f"fn {func_name}(") or line.startswith(f"pub fn {func_name}("):
            in_func = True
            start_idx = i
        
        if in_func:
            func_lines.append(line)
            brace_count += line.count('{')
            brace_count -= line.count('}')
            
            if brace_count == 0 and len(func_lines) > 0:
                end_idx = i
                break
                
    return start_idx, end_idx, func_lines

def extract_all_dispatch_funcs(lines):
    funcs = []
    for line in lines:
        match = re.match(r'^(?:pub )?fn (dispatch[A-Z]\w+)\(', line)
        if match:
            funcs.append(match.group(1))
    return funcs

all_funcs = extract_all_dispatch_funcs(lines)

print(f"Found {len(all_funcs)} dispatch functions")
