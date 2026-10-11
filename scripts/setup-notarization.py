#!/usr/bin/env python3
"""Interactively validate Apple notarization credentials and configure MClean CI."""

import getpass
import json
import re
import shutil
import subprocess
import sys


REPOSITORY = "maclifevn/MClean"
TEAM_ID = "CF5PGH3KGK"


def redact(message, sensitive_values):
    for value in sensitive_values:
        if value:
            message = message.replace(value, "[redacted]")
    return message


def run_checked(arguments, *, input_text=None, sensitive_values=()):
    try:
        result = subprocess.run(
            arguments,
            input=input_text,
            text=True,
            capture_output=True,
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError("Command timed out; no credential values were printed.") from None
    if result.returncode:
        detail = redact(result.stderr.strip() or result.stdout.strip(), sensitive_values)
        raise RuntimeError(detail or "Command failed without diagnostic output.")
    return result.stdout


def main():
    if not sys.stdin.isatty():
        raise RuntimeError("Run this command yourself in an interactive Terminal.")
    for name in ("xcrun", "gh"):
        if not shutil.which(name):
            raise RuntimeError(f"Required command is missing: {name}")
    run_checked(["gh", "auth", "status"])

    print(f"Configure notarization for {REPOSITORY}, Apple Team {TEAM_ID}.")
    print("Credentials are validated with Apple, then saved as GitHub Actions secrets.")
    print("The password is hidden and is not written to a file or shell history.")
    apple_id = input("Apple ID: ").strip()
    if not apple_id or any(character.isspace() for character in apple_id):
        raise RuntimeError("Enter your Developer Apple ID without spaces.")
    password = getpass.getpass("App-specific password (hidden): ").strip()
    if not re.fullmatch(r"[a-zA-Z]{4}(?:-[a-zA-Z]{4}){3}", password):
        raise RuntimeError("Expected an app-specific password in xxxx-xxxx-xxxx-xxxx format.")

    sensitive_values = (password, apple_id)
    print("Validating credentials with Apple…")
    history = run_checked(
        [
            "xcrun", "notarytool", "history",
            "--apple-id", apple_id,
            "--password", password,
            "--team-id", TEAM_ID,
            "--output-format", "json",
        ],
        sensitive_values=sensitive_values,
    )
    response = json.loads(history)
    if not isinstance(response, dict) or not isinstance(response.get("history"), list):
        raise RuntimeError("Apple returned an unexpected response; secrets were not changed.")

    for name, value in (
        ("NOTARIZATION_APPLE_ID", apple_id),
        ("NOTARIZATION_APP_PASSWORD", password),
    ):
        run_checked(
            ["gh", "secret", "set", name, "--repo", REPOSITORY],
            input_text=value,
            sensitive_values=sensitive_values,
        )
        print(f"Configured {name}.")
    print("Done. Both notarization secrets are configured; no release was published.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError) as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
    except (KeyboardInterrupt, EOFError):
        print("\nCancelled.", file=sys.stderr)
        sys.exit(1)
