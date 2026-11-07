"""Duplicate-object lint for normative SQL blocks in a Markdown architecture file.
Only ```sql fences are normative; ```text or prose is historical/non-executable."""
import re,sys,collections
t=open(sys.argv[1]).read()
blocks=[(m.start(),m.group(1)) for m in re.finditer(r'```sql\n(.*?)```',t,re.S)]
defs=collections.defaultdict(list); alters=[]
pat=re.compile(r'\bcreate\s+(?:or\s+replace\s+)?(?:unique\s+)?(table|view|type|function|index|extension|role|schema|trigger)\s+(?:if\s+not\s+exists\s+)?([a-z_][\w.]*)',re.I)
for pos,b in blocks:
    line=t[:pos].count('\n')+1
    body=re.sub(r'--[^\n]*','',b)
    for m in re.finditer(r'create\s+(?:constraint\s+)?trigger\s+(\w+)\s+.*?\bon\s+([\w.]+)',body,re.I|re.S):
        defs[('trigger',m.group(1).lower()+' on '+m.group(2).lower())].append(line)
    for m in re.finditer(r"create trigger t_append_only before update or delete on bnx\.%I",body):
        pass   # dynamic per-table triggers (format with %I) are generated from a table list
    for m in pat.finditer(body):
        kind,name=m.group(1).lower(),m.group(2).lower()
        if kind=='trigger': continue
        if kind=='index': kind='index'
        if kind in('table','view'): kind='relation'
        defs[(kind,name)].append(line)
    for m in re.finditer(r'\balter\s+table\s+([a-z_][\w.]*)',body,re.I): alters.append((m.group(1).lower(),line))
dups={k:v for k,v in defs.items() if len(v)>1 and k[0]!='function'}
print(f"sql blocks: {len(blocks)}; objects: {len(defs)}")
print("DUPLICATES:",dups if dups else "none")
rels={n for (k,n) in defs if k=='relation'}
print("ALTER on relations not created in any block:",sorted({a for a,l in alters if a not in rels}))
sys.exit(1 if dups else 0)
