# Contributing to Pulse

## Git Workflow

### Branches

Always create a feature branch from `main`. Never commit directly to `main`.

```
main          ← protected, CI must pass before merging
└── feat/auth-system
└── fix/socket-reconnect
└── chore/update-deps
```

Branch naming: `<type>/<short-description>` using the same types as commit messages below.

### Conventional Commits

Every commit message must follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<optional scope>): <short description>
```

| Type | When to use |
|------|-------------|
| `feat` | New feature |
| `fix` | Bug fix |
| `chore` | Tooling, deps, config (no production code change) |
| `refactor` | Code change that is neither a fix nor a feature |
| `docs` | Documentation only |
| `test` | Adding or updating tests |
| `ci` | CI/CD pipeline changes |

**Examples:**
```
feat(monitors): add pause/resume toggle
fix(auth): correct token expiry header
chore: upgrade prisma to 7.5
ci: add docker build step to pipeline
```

### Pull Request Flow

1. Branch off `main`: `git checkout -b feat/my-feature`
2. Make commits following Conventional Commits
3. Push and open a PR targeting `main`
4. CI must be green (lint → test → build) before merge
5. Squash-merge into `main`
