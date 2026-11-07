# bbot module dependencies (the unhashed half of the venv)

`requirements-bbot.lock` pins bbot's own 68 dependencies with SHA-256 hashes. On top of
that, the Dockerfile runs `bbot -y --install-all-deps`, which pip-installs the
per-module dependencies bbot discovers at runtime. Those are **not** pinned or hashed:
pip picks the newest release compatible with each module's constraint, so this list can
change between builds of the same Dockerfile.

Regenerate after changing `BBOT_VERSION`:

```bash
docker build --target bbotdeps -t artex-bbotdeps .
docker run --rm -v "$PWD/requirements-bbot.lock:/tmp/lock:ro" \
  -v "$PWD/scripts/bbot-module-deps.py:/tmp/gen.py:ro" \
  --entrypoint /opt/bbot/bin/python artex-bbotdeps /tmp/gen.py
```

If you need these verified too, generate a second lock with
`uv pip compile --generate-hashes` from the list below, install it with
`--require-hashes` right after `requirements-bbot.lock`, and drop
`--install-all-deps` (then only modules whose deps are in that lock will work).

40 distributions installed by `bbot -y --install-all-deps` beyond the 68 in requirements-bbot.lock
total: 234 MB

| package | version | MB |
|---|---|---|
| `kreuzberg` | 4.4.6 | 91.0 |
| `numpy` | 2.5.4 | 56.3 |
| `Django` | 5.2.19 | 23.0 |
| `SQLAlchemy` | 2.1.8 | 18.2 |
| `asyncpg` | 0.32.0 | 14.0 |
| `pypdfium2` | 5.15.0 | 8.9 |
| `aiokafka` | 0.12.0 | 4.3 |
| `pymongo` | 4.19.0 | 3.9 |
| `badsecrets` | 1.2.1 | 3.8 |
| `multidict` | 7.2.1 | 1.8 |
| `neo4j` | 6.4.1 | 1.5 |
| `pytz` | 2026.6 | 1.0 |
| `propcache` | 0.5.4 | 0.9 |
| `Werkzeug` | 3.1.9 | 0.8 |
| `python-whois` | 0.9.6 | 0.5 |
| `click` | 8.5.1 | 0.4 |
| `python-dateutil` | 2.9.0.post0 | 0.4 |
| `yarl` | 1.25.1 | 0.4 |
| `nats-py` | 2.16.0 | 0.3 |
| `Flask` | 3.1.3 | 0.3 |
| `Markdown` | 3.4.4 | 0.3 |
| `baddns` | 2.4.1 | 0.3 |
| `aiomysql` | 0.3.2 | 0.2 |
| `aio-pika` | 9.5.8 | 0.2 |
| `pamqp` | 3.3.0 | 0.2 |
| `sqlparse` | 0.6.1 | 0.2 |
| `PyMySQL` | 1.2.3 | 0.1 |
| `wafw00f` | 2.3.2 | 0.1 |
| `aiormq` | 6.9.4 | 0.1 |
| `sqlmodel` | 0.0.48 | 0.1 |
| `asgiref` | 3.13.0 | 0.1 |
| `colorama` | 0.4.6 | 0.1 |
| `aiosqlite` | 0.22.1 | 0.1 |
| `PySocks` | 1.7.1 | 0.0 |
| `itsdangerous` | 2.2.0 | 0.0 |
| `six` | 1.17.0 | 0.0 |
| `flask-unsign` | 1.2.1 | 0.0 |
| `blinker` | 1.9.0 | 0.0 |
| `pluginbase` | 1.0.1 | 0.0 |
| `async-timeout` | 5.0.1 | 0.0 |
