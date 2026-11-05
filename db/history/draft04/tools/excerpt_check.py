"""Execute every not-yet-migrated DDL excerpt of the architecture on top of migrations 0001-0007, statements ordered by
foreign-key dependency, in ONE transaction. Draft-01 tables that Draft-04 references but does not restate get stubs."""
import re,subprocess,sys
doc=open(sys.argv[1]).read(); SV=sys.argv[2]
body=doc[:doc.index('## Appendix B-M')]
stmts=[]
for b in re.findall(r'```sql\n(.*?)```',body,re.S):
    if 'resolve_actor' in b: continue
    clean=re.sub(r'--[^\n]*','',b)
    for s in re.split(r';\s*\n',clean):
        s=s.strip().rstrip(';')
        if s: stmts.append(s+';')
def name(s):
    m=re.match(r'create\s+(?:table|type|unique index|index)\s+(?:\w+\s+on\s+)?([\w.]+)',s,re.I); return m.group(1) if m else None
defined={name(s) for s in stmts if s.lower().startswith('create table')}
order=[]; done=set(); pending=list(stmts)
while pending:
    progress=False
    for s in list(pending):
        refs=set(re.findall(r'references\s+([\w.]+)',s,re.I))-{name(s)}
        if all(r in done or r not in defined for r in refs):
            order.append(s); pending.remove(s); done.add(name(s)); progress=True
    if not progress: order+=pending; break
stub="create table bnx.ai_connection(id uuid primary key);  -- Draft-01 table, stub for this check\n"
sql="set role bnx_definer;\n"+stub+"\n".join(order)+"\nselect count(*) from pg_tables where schemaname='bnx';\n"
r=subprocess.run(['psql',SV,'-X','-q','-At','-v','ON_ERROR_STOP=1','-1'],input=sql,text=True,capture_output=True)
print("statements:",len(order),"| result:", "OK, bnx tables now "+r.stdout.strip() if r.returncode==0 else "ERROR "+r.stderr.strip()[:300])
sys.exit(r.returncode)
