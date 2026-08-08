"""Change inventory: machine-readable Git range parsing."""
from __future__ import annotations
import re, subprocess
from dataclasses import dataclass, field
from typing import List, Optional, Tuple
from ..errors import GitError, UsageError
from ..git.repository import GitRepository
from ..models import RecentCommit
@dataclass
class ChangedFile:
    path: str; status: str; old_path: Optional[str]=None; ranges: List[Tuple[int,int]]=field(default_factory=list); extension: str=""
@dataclass
class Inventory:
    range_spec: str; base: str; head: str; base_oid: str; head_oid: str; commits: List[RecentCommit]=field(default_factory=list); files: List[ChangedFile]=field(default_factory=list); has_rename: bool=False; dirty_note: Optional[str]=None
_HUNK_RE=re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
GIT_TIMEOUT=60
def _resolve(repo, ref):
    out=repo.run_ok("rev-parse","--verify",f"{ref}^{{commit}}")
    if out is None: raise GitError(f"cannot resolve '{ref}' to a commit")
    return out.strip()
def _parse_range(repo, range_spec):
    spec=(range_spec or "").strip()
    if not spec: raise UsageError("empty diff range; expected something like main..HEAD or HEAD~5..HEAD")
    if ".." in spec:
        base_s,_,head_s=spec.partition(".."); base_s=base_s.strip(); head_s=head_s.strip()
        if not base_s: raise UsageError(f"invalid diff range '{spec}': missing base before '..'")
        if not head_s: head_s="HEAD"
    else: base_s,head_s=spec,"HEAD"
    return base_s,head_s,_resolve(repo,base_s),_resolve(repo,head_s)
def _run_bytes(repo, *args):
    cmd=["git","-C",str(repo.root)]+list(args)
    proc=subprocess.run(cmd,capture_output=True,timeout=GIT_TIMEOUT)
    if proc.returncode!=0:
        msg=(proc.stderr or proc.stdout).decode(errors="replace").strip()
        raise GitError(f"git {' '.join(args)} failed ({proc.returncode}): {msg}")
    return proc.stdout
def _commits(repo, base_oid, head_oid):
    raw=_run_bytes(repo,"log","--format=%H%x1f%h%x1f%s%x1f%an%x1f%aI%x00",f"{base_oid}..{head_oid}")
    commits=[]
    for rec in raw.split(b"\x00"):
        if not rec: continue
        txt=rec.decode(errors="replace").lstrip("\r\n")
        txt=txt.strip()
        if not txt: continue
        parts=txt.split("\x1f")
        if len(parts)>=5:
            commits.append(RecentCommit(hash=parts[0].strip(),short=parts[1].strip(),subject=parts[2],author=parts[3],date=parts[4]))
    return commits
def _name_status_z(repo, base_oid, head_oid):
    raw=_run_bytes(repo,"diff","--name-status","-z","--find-renames",f"{base_oid}..{head_oid}")
    tokens=raw.split(b"\x00"); out=[]; i=0
    while i<len(tokens):
        if not tokens[i]: i+=1; continue
        status=tokens[i].decode(errors="replace"); i+=1
        if status.startswith("R") or status.startswith("C"):
            if i+1>=len(tokens): break
            old=tokens[i].decode(errors="replace") if tokens[i] else ""; new=tokens[i+1].decode(errors="replace") if tokens[i+1] else ""; i+=2; out.append((status,new,old))
        else:
            if i>=len(tokens): break
            path=tokens[i].decode(errors="replace") if tokens[i] else ""; i+=1; out.append((status,path,None))
    return [(s,p,o) for s,p,o in out if p]
def _hunk_ranges(repo, base_oid, head_oid, files):
    raw=_run_bytes(repo,"diff","--unified=0","--no-color",f"{base_oid}..{head_oid}")
    by_path={f.path:f for f in files}; cur=None
    for lb in raw.splitlines():
        line=lb.decode(errors="replace")
        if line.startswith("diff --git"):
            cur=by_path.get(line.rsplit(" b/",1)[-1].strip('"')) if " b/" in line else None; continue
        if cur is None or cur.status.startswith("D"): continue
        if line.startswith("@@"):
            m=_HUNK_RE.match(line)
            if m:
                st=int(m.group(1)); cnt=m.group(2); c=int(cnt) if cnt else 1
                if c>0: cur.ranges.append((st,st+c-1))
def build_inventory(repo, range_spec):
    base_s,head_s,base_oid,head_oid=_parse_range(repo, range_spec)
    inv=Inventory(range_spec=range_spec,base=base_s,head=head_s,base_oid=base_oid,head_oid=head_oid)
    try: inv.commits=_commits(repo,base_oid,head_oid)
    except GitError: inv.commits=[]
    rows=_name_status_z(repo,base_oid,head_oid)
    import pathlib as _pl
    for status,path,old_path in rows:
        ext=_pl.Path(path).suffix.lower().lstrip("."); inv.files.append(ChangedFile(path=path,status=status,old_path=old_path,extension=ext))
        if status.startswith("R") or status.startswith("C"): inv.has_rename=True
    try: _hunk_ranges(repo,base_oid,head_oid,inv.files)
    except GitError: pass
    try:
        wt=repo.run_ok("status","--porcelain")
        if wt and wt.strip(): inv.dirty_note=f"working tree has {len([l for l in wt.splitlines() if l.strip()])} dirty/untracked file(s) not in range"
    except Exception: pass
    inv.files.sort(key=lambda f:f.path)
    for f in inv.files: f.ranges.sort()
    return inv
