# Contributing to Perstalk

Thanks for taking the time to look at the project. Perstalk is small on
purpose — a few hundred lines of Python and a single HTML file — and the goal
is to keep it that way: easy to read, easy to fork, easy to run on any
Apple Silicon Mac in one command.

## Quick links

- [Open an issue](https://github.com/nitish20899/perstalk/issues/new/choose)
- [Submit a PR](https://github.com/nitish20899/perstalk/compare)
- [Project README](./README.md)

## Reporting bugs

Please use the **Bug report** template so we have everything needed to
reproduce. The most useful things to include:

- macOS version (`sw_vers`)
- Apple Silicon chip (`sysctl -n machdep.cpu.brand_string`)
- Python version (`python3 --version`)
- The terminal output from `./start.sh` showing the failure
- The output of `curl -s http://127.0.0.1:5050/status` if the server is up

## Suggesting features

Use the **Feature request** template. A short description of the user
problem usually beats a detailed implementation proposal — if Perstalk is
the right tool to solve it, the design discussion can happen on the issue.

## Development setup

```bash
git clone https://github.com/nitish20899/perstalk.git
cd perstalk
./start.sh        # creates .venv and installs deps on first run
```

To install the dev tools:

```bash
source .venv/bin/activate
pip install ruff
```

## Code style

Python is formatted and linted with [Ruff](https://docs.astral.sh/ruff/):

```bash
source .venv/bin/activate
ruff check .
ruff format .
```

CI runs the same checks on every push and PR (`.github/workflows/ci.yml`).

There's no JS/CSS toolchain — `index.html` is plain HTML, vanilla JavaScript,
and hand-written CSS. Please keep it that way.

## Pull requests

- Keep PRs **focused** — one feature or fix per PR.
- Run `ruff check .` and `ruff format .` before pushing.
- If your change affects user-visible behavior, update the README (and a
  screenshot if relevant — see `docs/screenshots/`).
- A short note in the PR description explaining the **why** is more valuable
  than a play-by-play of the diff.

## License

By contributing, you agree that your contributions will be licensed under
the project's [MIT License](./LICENSE).
