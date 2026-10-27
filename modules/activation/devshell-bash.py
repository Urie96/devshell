#!/usr/bin/env python3
"""devshell-bash -- render a `nix print-dev-env --json` dump as bash code.

This tool never runs nix. It reads the JSON document that
`nix print-dev-env --json` prints (from a file or stdin) and writes a bash
script that merges the devShell into the current shell:

    nix print-dev-env --json | devshell-bash
    nix print-dev-env --json > env.json && devshell-bash env.json
    source <(nix print-dev-env --json | devshell-bash)

Unlike `nix develop`, sourcing the output does not start a subshell, so the
user's prompt/aliases/history stay intact, and the devShell's PATH still ends
up in front of whatever the user's rc files prepended.

The emitted code does NOT bake in the caller's environment. Colon-separated
variables are emitted as a prepend that references the shell's own value at
source time, e.g.

    export PATH='/devshell/bin'"${PATH:+:$PATH}"

which is what `nix develop` / `nix print-dev-env` do with their nix_saved_PATH
dance. Everything the devShell does not define is simply inherited by the
shell.

The devShell's `shellHook` is included and runs like it does under `nix
develop`. `nix print-dev-env --json` also dumps lib.stdenv's whole build
machinery as bashFunctions; only the functions the shellHook actually
references are emitted (pass --all-functions for the full set).
"""

from __future__ import annotations

import argparse
import json
import re
import sys

__version__ = "0.3.0"

# Variables that `nix print-dev-env` exports out of the *build* sandbox but that
# are meaningless (or actively harmful) in an interactive shell. This mirrors
# what nix-shell activation scripts unset after sourcing the devShell env.
#
# Only `type == "exported"` variables ever reach this set (see parse_dev_env),
# so bash-only `var`/`array` internals (BASH, IFS, HOSTTYPE, PS4, the *Hooks
# arrays, defaultBuildInputs, checkPhase, ...) are already filtered out and do
# not need to be listed here.
DENY = {
    # sandbox locations / values that do not exist on the host
    "HOME",
    "TEMP",
    "TEMPDIR",
    "TMP",
    "TMPDIR",
    "NIX_BUILD_TOP",
    "NIX_BUILD_CORES",
    "OLDPWD",
    # terminal / shell session values we must not clobber
    "TERM",
    "TZ",
    "SHELL",
    "CONFIG_SHELL",
    "shell",
    # build-time bookkeeping (SOURCE_DATE_EPOCH=1980, /no-cert-file.crt, ...)
    "SOURCE_DATE_EPOCH",
    "NIX_STORE",
    "NIX_ENFORCE_PURITY",
    "NIX_ENFORCE_NO_NATIVE",
    "NIX_LOG_FD",
    # compiler/linker flags that would poison native builds
    "NIX_CFLAGS_COMPILE",
    "NIX_LDFLAGS",
    # stdenv derivation internals
    "__structuredAttrs",
    # Darwin sandbox attributes and allowSubstitutes: derivation attributes that
    # only the nix daemon reads, out of the .drv rather than out of $env. A
    # `false`/`[]` value reaches us as an empty string.
    "__darwinAllowLocalNetworking",
    "__impureHostDeps",
    "__propagatedImpureHostDeps",
    "__propagatedSandboxProfile",
    "__sandboxProfile",
    "allowSubstitutes",
    "strictDeps",
    "phases",
    "buildPhase",
    "builder",
    "outputs",
    "out",
    "name",
    "system",
    "stdenv",
    "patches",
    "doCheck",
    "doInstallCheck",
    "dontAddDisableDepTrack",
    "preferLocalBuild",
    "nativeBuildInputs",
    "buildInputs",
    "propagatedBuildInputs",
    "propagatedNativeBuildInputs",
    "cmakeFlags",
    "configureFlags",
    "mesonFlags",
    "HOST_PATH",
    # not a normal variable: it is a bash snippet, emitted separately at the end
    # of the output (see emit)
    "shellHook",
    # defensive: not produced by `print-dev-env --json` today, but they are set
    # by nix's makeRcScript (the non-JSON path), so keep them out either way
    "PWD",
    "nix_saved_PATH",
    "nix_saved_XDG_DATA_DIRS",
}
DENY_PREFIX = ("depsBuild", "depsHost", "depsTarget", "output")

# bashFunctions is `declare -F` after sourcing lib.stdenv's setup, i.e. all of
# nixpkgs' build machinery. `nix develop` writes every one of them into its
# throw-away shell, but we source into the user's interactive shell, where 90
# stdenv internals (substitute, runHook, exitHandler, ...) are just namespace
# pollution. By default only the functions the shellHook references (and what
# those reference, transitively) are emitted; --all-functions emits everything.
DENY_FUNCTIONS = {
    # `shellHook` is a variable holding a snippet, not a function; if some
    # devShell does define a function by that name, nix develop still only
    # evaluates the variable.
    "shellHook",
}

IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

# Colon-separated variables. The devShell's value is *prepended* to the shell's
# own value (this is exactly the `savedVars` list in nix's src/nix/develop.cc,
# plus the usual extras).
PATH_VARS = {"PATH", "CDPATH", "MANPATH", "FPATH", "XDG_DATA_DIRS"}


def shq(value: str) -> str:
    return "'" + value.replace("'", "'\\''") + "'"


def keep(name: str) -> bool:
    return name not in DENY and not name.startswith(DENY_PREFIX)


def referenced_functions(functions: dict[str, str], shell_hook: str) -> dict[str, str]:
    """The bashFunctions the shellHook may call, transitively.

    Over-approximates by scanning every identifier in the shellHook and in the
    bodies of the functions it reaches; identifiers that are not function names
    are simply ignored. Indirect calls (`eval`, `"$cmd"`) are not followed, so
    --all-functions exists as an escape hatch.
    """
    pending = IDENT.findall(shell_hook)
    used: set[str] = set()
    while pending:
        name = pending.pop()
        if name in used or name not in functions:
            continue
        used.add(name)
        pending.extend(IDENT.findall(functions[name]))
    return {name: functions[name] for name in used}


def parse_dev_env(raw: bytes) -> tuple[dict[str, str], dict[str, str], str]:
    """Pick the devShell's own environment out of a print-dev-env dump.

    Returns (exported variables, bash functions, shellHook snippet).
    """
    doc = json.loads(raw)
    if not isinstance(doc, dict) or not isinstance(doc.get("variables"), dict):
        raise ValueError("not a `nix print-dev-env --json` document (no 'variables')")

    variables = doc["variables"]

    env: dict[str, str] = {}
    for name, spec in variables.items():
        if not isinstance(spec, dict) or spec.get("type") != "exported":
            continue
        if not keep(name):
            continue
        env[name] = spec.get("value", "")

    functions = doc.get("bashFunctions") or {}
    if not isinstance(functions, dict):
        raise ValueError("'bashFunctions' is not an object")
    functions = {
        name: body
        for name, body in functions.items()
        if name not in DENY_FUNCTIONS and isinstance(body, str)
    }

    shell_hook = variables.get("shellHook") or {}
    shell_hook = shell_hook.get("value", "") if isinstance(shell_hook, dict) else ""

    return env, functions, shell_hook


def emit(
    env: dict[str, str],
    functions: dict[str, str],
    shell_hook: str,
    source: str,
    all_functions: bool = False,
) -> str:
    lines = [f"# devshell-bash: {source} (bash)"]

    if all_functions:
        # Every bashFunction in the dump, exactly like nix develop.
        needed = functions
    elif shell_hook.strip():
        needed = referenced_functions(functions, shell_hook)
    else:
        # Nothing will run the stdenv helpers: keep the output a plain list of
        # exports instead of dragging in the whole stdenv.
        needed = {}

    if needed:
        lines.append(
            "# bash functions from the devShell (all of them)"
            if all_functions
            else "# bash functions the shellHook needs"
        )
        for name in sorted(needed):
            body = needed[name].strip("\n")
            lines.append(f"{name} ()")
            lines.append("{")
            lines.append(body)
            lines.append("}")

    for name in sorted(env):
        value = env[name]
        if name in PATH_VARS:
            if not value:
                continue
            # 'devshell'"${PATH:+:$PATH}" -- prepend, inherit the rest at source time
            lines.append(
                f"export {name}={shq(value)}" + '"${' + name + ":+:$" + name + '}"'
            )
        else:
            lines.append(f"export {name}={shq(value)}")

    if shell_hook.strip():
        lines.append("")
        lines.append("# shellHook")
        lines.append(shell_hook.rstrip("\n"))

    return "\n".join(lines) + "\n"


def read_input(path: str) -> tuple[bytes, str]:
    if path == "-":
        return sys.stdin.buffer.read(), "<stdin>"
    try:
        with open(path, "rb") as handle:
            return handle.read(), path
    except OSError as error:
        raise SystemExit(f"devshell-bash: {error}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="devshell-bash",
        description=(
            "Render `nix print-dev-env --json` output as bash code that merges "
            "a devShell into the current shell (no subshell, no rc-file hacking)."
        ),
        epilog=(
            "examples:\n"
            "  source <(nix print-dev-env --json | devshell-bash)\n"
            "  nix print-dev-env --json > env.json\n"
            "  devshell-bash env.json > activate.bash\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "input",
        nargs="?",
        metavar="FILE",
        default="-",
        help="JSON from `nix print-dev-env --json` (default: -, i.e. stdin)",
    )
    parser.add_argument(
        "--all-functions",
        action="store_true",
        help=(
            "emit every bashFunction from the JSON (what nix develop does) "
            "instead of only the ones the shellHook references"
        ),
    )
    parser.add_argument(
        "--version", action="version", version=f"%(prog)s {__version__}"
    )
    args = parser.parse_args(argv)

    raw, source = read_input(args.input)
    try:
        env, functions, shell_hook = parse_dev_env(raw)
    except (ValueError, json.JSONDecodeError) as error:
        raise SystemExit(f"devshell-bash: cannot parse {source}: {error}")

    sys.stdout.write(emit(env, functions, shell_hook, source, args.all_functions))
    return 0


if __name__ == "__main__":
    sys.exit(main())
