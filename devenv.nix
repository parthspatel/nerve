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
  };

  packages = [
    pkgs.git
    pkgs.jq
    pkgs.sqlx-cli
    pkgs.pnpm
    pkgs.playwright
    pkgs.playwright-test
    pkgs.playwright-driver
  ];

  # JavaScript/TypeScript with pnpm
  languages.javascript = {
    enable = true;
    package = pkgs.nodejs_22;
    pnpm = {
      enable = true;
      install.enable = true;
    };
  };

  # Custom scripts
  scripts = {
    gsd.exec = ''
      npx get-shit-done-cc@latest "$@"
    '';
  };

  # Git hooks
  difftastic.enable = true;
  git-hooks.hooks = {
    nixfmt.enable = true;
    rustfmt.enable = true;
    # clippy.enable = true;
    shfmt.enable = true;
    shellcheck.enable = true;
    action-validator.enable = true;
    commitizen.enable = true;
  };

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
      #     fi
      #   '';
      # };
    };
  };
}
