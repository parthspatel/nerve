{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:

{
  env = {
    NPM_CONFIG_CACHE = ".devenv/npm-cache";
    NPM_CONFIG_PREFIX = ".devenv/npm-global";
    JAVA_HOME = "${config.languages.java.jdk.package}/lib/openjdk";
    GRADLE_USER_HOME = ".devenv/gradle";
    UV_CACHE_DIR = ".devenv/uv-cache";
    GOPATH = ".devenv/go";
    GOBIN = ".devenv/go/bin";
  };

  packages = [
    # Core tools
    pkgs.git
    pkgs.jq
    pkgs.yq-go
    pkgs.curl
    pkgs.wget
    pkgs.ripgrep
    pkgs.fd
    pkgs.tree
    pkgs.just # command runner (Makefile alternative)

    # Database tooling
    pkgs.sqlx-cli
    pkgs.postgresql_16 # psql client

    # Node.js / Frontend
    pkgs.pnpm
    pkgs.playwright
    pkgs.playwright-test
    pkgs.playwright-driver

    # Java / Flink
    pkgs.gradle
    pkgs.maven

    # Python tooling
    pkgs.uv # fast Python package manager

    # Kubernetes tooling
    pkgs.kubectl
    pkgs.kubernetes-helm
    pkgs.helmfile
    pkgs.kustomize
    pkgs.k9s # terminal UI for K8s
    pkgs.stern # multi-pod log tailing
    pkgs.argocd # ArgoCD CLI

    # Container tooling
    pkgs.docker-compose

    # Data tooling
    pkgs.duckdb # local analytics / Splink dev

    # Healthcare tooling
    pkgs.protobuf # schema compilation

    # Observability
    pkgs.grafana-loki # logcli
    pkgs.promtool # Prometheus rule validation
  ];

  # ── Go (MLLP ingestion, connectors) ──────────────────────────
  languages.go = {
    enable = true;
    package = pkgs.go_1_22;
  };

  # ── Java 21 LTS (Flink processing, HAPI HL7v2) ──────────────
  languages.java = {
    enable = true;
    jdk.package = pkgs.jdk21;
    gradle = {
      enable = true;
    };
    maven.enable = true;
  };

  # ── Python 3.12 (Splink MPI, SQLMesh, DICOM extraction) ─────
  languages.python = {
    enable = true;
    package = pkgs.python312;
    uv = {
      enable = true;
      sync.enable = true;
    };
  };

  # ── JavaScript/TypeScript (Clinical UIs) ─────────────────────
  languages.javascript = {
    enable = true;
    package = pkgs.nodejs_22;
    pnpm = {
      enable = true;
      install.enable = true;
    };
  };

  # ── Rust (tooling only — formatting, dev utilities) ──────────
  languages.rust = {
    enable = true;
    channel = "stable";
  };

  # ── Nix formatting ──────────────────────────────────────────
  languages.nix.enable = true;

  # Custom scripts
  scripts = {
    # Main dev command runner
    gsd.exec = ''
      npx get-shit-done-cc@latest "$@"
    '';

    # Run all linters
    nerve-lint.exec = ''
      echo "==> Linting Go..."
      (cd ingestion && go vet ./...) 2>/dev/null || true
      echo "==> Linting Java..."
      (cd processing && gradle check --no-daemon) 2>/dev/null || true
      echo "==> Linting Python..."
      (cd mpi/splink-jobs && uv run ruff check .) 2>/dev/null || true
      echo "==> Linting TypeScript..."
      (cd ui/mapping-studio && pnpm lint) 2>/dev/null || true
      echo "==> Done."
    '';

    # Run all tests
    nerve-test.exec = ''
      echo "==> Testing Go..."
      (cd ingestion && go test ./...) 2>/dev/null || true
      echo "==> Testing Java..."
      (cd processing && gradle test --no-daemon) 2>/dev/null || true
      echo "==> Testing Python..."
      (cd mpi/splink-jobs && uv run pytest) 2>/dev/null || true
      echo "==> Testing TypeScript..."
      (cd ui/mapping-studio && pnpm test) 2>/dev/null || true
      echo "==> Done."
    '';

    # SQLMesh plan (dry-run transforms)
    nerve-plan.exec = ''
      cd transforms/sqlmesh && uv run sqlmesh plan --no-prompts "$@"
    '';

    # Start local development Kafka + PostgreSQL
    nerve-up.exec = ''
      docker-compose -f deploy/docker-compose.dev.yml up -d
    '';

    nerve-down.exec = ''
      docker-compose -f deploy/docker-compose.dev.yml down
    '';
  };

  # Process management for local development
  processes = {
    # Local Kafka via docker-compose (if not using K8s)
    # kafka.exec = "docker-compose -f deploy/docker-compose.dev.yml up kafka";
  };

  # Git hooks
  difftastic.enable = true;
  git-hooks.hooks = {
    # Nix
    nixfmt.enable = true;

    # Rust (tooling)
    rustfmt.enable = true;

    # Shell
    shfmt.enable = true;
    shellcheck.enable = true;

    # GitHub Actions
    action-validator.enable = true;

    # Conventional commits
    commitizen.enable = true;

    # Go
    govet = {
      enable = true;
      entry = "go vet ./...";
      pass_filenames = false;
      types = [ "go" ];
    };

    # Python
    ruff = {
      enable = true;
      entry = "uv run ruff check --fix";
      types = [ "python" ];
    };
  };

  # Pre/post shell hooks
  enterShell = ''
    echo ""
    echo "  ⚡ NERVE Development Environment"
    echo "  ─────────────────────────────────"
    echo "  Go:         $(go version 2>/dev/null | cut -d' ' -f3 || echo 'not found')"
    echo "  Java:       $(java --version 2>/dev/null | head -1 || echo 'not found')"
    echo "  Python:     $(python --version 2>/dev/null || echo 'not found')"
    echo "  Node.js:    $(node --version 2>/dev/null || echo 'not found')"
    echo "  Rust:       $(rustc --version 2>/dev/null || echo 'not found')"
    echo ""
    echo "  Commands:"
    echo "    nerve-lint    Run all linters"
    echo "    nerve-test    Run all tests"
    echo "    nerve-plan    SQLMesh plan (dry-run)"
    echo "    nerve-up      Start local dev services"
    echo "    nerve-down    Stop local dev services"
    echo "    gsd           Get stuff done (AI-assisted)"
    echo ""
  '';

  # Claude Code integration
  claude.code = {
    enable = true;
    commands = {

    };
    hooks = {
      protect-secrets = {
        enable = true;
        name = "Protect sensitive files";
        hookType = "PreToolUse";
        matcher = "^(Edit|MultiEdit|Write)$";
        command = ''
          json=$(cat)
          file_path=$(echo "$json" | jq -r '.file_path // empty')

          if [[ "$file_path" =~ \.(env|secret)$ ]]; then
            echo "Error: Cannot edit sensitive files"
            exit 1
          fi
        '';
      };

      # Run tests after changes (PostToolUse hook)
      # test-on-save = {
      #   enable = true;
      #   name = "Run tests after edit";
      #   hookType = "PostToolUse";
      #   matcher = "^(Edit|MultiEdit|Write)$";
      #   command = ''
      #     # Read the JSON input from stdin
      #     json=$(cat)
      #     file_path=$(echo "$json" | jq -r '.file_path // empty')

      #     if [[ "$file_path" =~ \.rs$ ]]; then
      #       cargo test
      #     elif [[ "$file_path" =~ \.(ts|tsx)$ ]]; then
      #       pnpm test
      #     elif [[ "$file_path" =~ \.go$ ]]; then
      #       go test ./...
      #     elif [[ "$file_path" =~ \.java$ ]]; then
      #       gradle test --no-daemon
      #     elif [[ "$file_path" =~ \.py$ ]]; then
      #       uv run pytest
      #     fi
      #   '';
      # };
    };
  };
}
