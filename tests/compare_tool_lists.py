# ADR-029 / ADR-031: compares two saved tools/list answers (JSON-RPC responses) and says whether
# the second still offers everything the first did.
#
# Only description text may differ.  Names, parameters, required, types, enums and annotations
# (with the MCP defaults applied) must be the same, except where src/McpToolAliases.pas says a
# name changed:
#   - a parameter entry renames the parameter in the old schema before it is compared;
#   - a tool entry (fusion or rename) retires a tool: the new tool must exist, offer every
#     parameter of the old one (renamed as the table says) with the same schema, take the fixed
#     argument, and have the same annotations.  The new tool may gain parameters.
# New tools that are not the target of an entry are listed, not counted as problems.
#
# usage: python compare_tool_lists.py before.json after.json [McpToolAliases.pas]
import json, os, re, sys

def load(p): return {t['name']: t for t in json.load(open(p))['result']['tools']}

def read_table(path):
    rx = re.compile(r"Kind:\s*(akTool|akParam);\s*Tool:\s*'([^']*)';\s*Old:\s*'([^']*)';\s*New:\s*'([^']*)';"
                    r"\s*FixedKey:\s*'([^']*)';\s*FixedVal:\s*'([^']*)'")
    return [m.groups() for m in rx.finditer(open(path, encoding='utf-8').read())]

here = os.path.dirname(os.path.abspath(__file__))
A, B = load(sys.argv[1]), load(sys.argv[2])
TABLE = read_table(sys.argv[3] if len(sys.argv) > 3 else os.path.join(here, '..', 'src', 'McpToolAliases.pas'))
TOOL_ALIAS = {t: (new, key) for kind, t, old, new, key, val in TABLE if kind == 'akTool'}
PARAMS = [(t, old, new) for kind, t, old, new, key, val in TABLE if kind == 'akParam']

DEF = {'readOnlyHint': False, 'destructiveHint': True, 'idempotentHint': False, 'openWorldHint': True}
def ann(t):
    a = dict(DEF); a.update({k: v for k, v in t.get('annotations', {}).items() if k != 'title'}); return a
def strip(o):
    if isinstance(o, dict): return {k: strip(v) for k, v in o.items() if k != 'description'}
    if isinstance(o, list): return [strip(v) for v in o]
    return o
def covers(pattern, name):
    return name.startswith(pattern[:-1]) if pattern.endswith('*') else pattern == name

def renamed(name, schema):
    """the old schema with the parameter names the table changed, descriptions stripped"""
    props = dict(strip(schema).get('properties', {}))
    req = list(schema.get('required', []))
    for t, old, new in PARAMS:
        if covers(t, name) and old in props:
            props[new] = props.pop(old)
            req = [new if r == old else r for r in req]
    return props, req

def check_pair(old, new_name, fixed_key, bad):
    """old tool (from A) retired into new_name (in B)"""
    n = B[new_name]
    props, req = renamed(old['name'], old['inputSchema'])
    nprops = strip(n['inputSchema']).get('properties', {})
    for k, v in props.items():
        if k not in nprops: print('MISSING PARAMETER:', old['name'], '->', new_name, '.', k); bad.append(1)
        elif nprops[k] != v: print('PARAMETER DIFFERS:', old['name'], '->', new_name, '.', k); bad.append(1)
    for r in req:
        if r not in n['inputSchema'].get('required', []): print('REQUIRED LOST:', old['name'], '->', new_name, '.', r); bad.append(1)
    if fixed_key and fixed_key not in nprops: print('FIXED ARGUMENT MISSING:', old['name'], '->', new_name, '.', fixed_key); bad.append(1)
    if ann(old) != ann(n): print('ANNOTATIONS DIFFER:', old['name'], '->', new_name, ann(old), ann(n)); bad.append(1)

bad = []
targets = {new for new, key in TOOL_ALIAS.values()}
for n in sorted(A):
    if n in B and n not in TOOL_ALIAS:
        a, b = A[n], B[n]
        pa, ra = renamed(n, a['inputSchema'])
        if n in targets:
            check_pair(a, n, '', bad)      # a fusion target may gain parameters, not lose any
        else:
            pb = strip(b['inputSchema']).get('properties', {})
            if pa != pb or sorted(ra) != sorted(b['inputSchema'].get('required', [])):
                print('SCHEMA DIFFERS (not descriptions):', n); bad.append(1)
            if ann(a) != ann(b): print('ANNOTATIONS DIFFER:', n, ann(a), ann(b)); bad.append(1)
        if a.get('title') != b.get('title') and a.get('annotations', {}).get('title') != b.get('annotations', {}).get('title'):
            print('TITLE DIFFERS:', n); bad.append(1)
    elif n in TOOL_ALIAS:
        new, key = TOOL_ALIAS[n]
        if n in B: print('RETIRED TOOL IS STILL LISTED:', n); bad.append(1)
        elif new not in B: print('TARGET MISSING:', n, '->', new); bad.append(1)
        else: check_pair(A[n], new, key, bad)
    else:
        print('TOOL DISAPPEARED WITHOUT AN ENTRY:', n); bad.append(1)
for n in sorted(set(B) - set(A)):
    if n not in targets: print('new tool (not a problem):', n)
c = lambda p: len(json.dumps(json.load(open(p))['result'], separators=(',', ':')))
print('tools', len(A), '->', len(B), '| compact bytes', c(sys.argv[1]), '->', c(sys.argv[2]), '| problems', len(bad))
sys.exit(1 if bad else 0)
