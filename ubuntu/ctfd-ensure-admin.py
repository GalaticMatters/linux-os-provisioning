#!/usr/bin/env python3
"""Create the CTFd web admin once from CTFD_USER / CTFD_PASSWORD.
Empty CTFD_PASSWORD skips. Failures must not block sshd."""
import os
import sys

os.chdir("/opt/CTFd")
sys.path.insert(0, "/opt/CTFd")

password = os.environ.get("CTFD_PASSWORD") or ""
if not password:
    raise SystemExit(0)

name = os.environ.get("CTFD_USER") or "ctfd"
email = os.environ.get("CTFD_ADMIN_EMAIL") or "ctfd@cybersecurity.lan"

from CTFd import create_app
from CTFd.models import Users, db

app = create_app()
with app.app_context():
    if Users.query.filter_by(name=name).first() is not None:
        raise SystemExit(0)
    if Users.query.filter_by(type="admin").first() is not None:
        raise SystemExit(0)
    user = Users(
        name=name,
        email=email,
        password=password,
        type="admin",
        verified=True,
    )
    db.session.add(user)
    db.session.commit()
    print("ctfd: created admin", name)
