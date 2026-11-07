import importlib.metadata as m, re, sys
lock = set()
for line in open('/tmp/lock'):
    mm = re.match(r'^([A-Za-z0-9._-]+)==', line.strip())
    if mm: lock.add(re.sub(r'[_.]', '-', mm.group(1)).lower())
rows = []
for d in m.distributions():
    name = d.metadata['Name']; norm = re.sub(r'[_.]', '-', name).lower()
    if norm in lock: continue
    try: size = sum((f.size or 0) for f in (d.files or [])) / 1e6
    except Exception: size = 0.0
    rows.append((norm, name, d.version, size))
rows.sort()
print(f"{len(rows)} distributions installed by `bbot -y --install-all-deps` beyond the 68 in requirements-bbot.lock")
print(f"total: {sum(r[3] for r in rows):.0f} MB")
print()
print("| package | version | MB |")
print("|---|---|---|")
for norm, name, ver, size in sorted(rows, key=lambda r: -r[3]):
    print(f"| `{name}` | {ver} | {size:.1f} |")
