# Input resolution helpers, exposed as `config.lib`.
#
# Two problems are solved here:
#
# 1. Not every dependency of a devshell wants to be a flake input. Projects
#    that keep some sources in niv (`nix/sources.json`) or that consume a
#    sub-flake just for a package need a uniform way to ask for "some input".
#    `config.lib.getInput` looks a name up in the flake's inputs first and
#    falls back to niv. `flake = false` inputs stay source trees: they are
#    returned as `{ outPath = "..."; }` and never evaluated as flakes.
#
# 2. A flake fetched by niv is a plain source tree, not an evaluated flake.
#    Evaluating it the usual way (`import`ing its flake.nix and passing the
#    freshly fetched versions of *its* inputs) would drag in a second nixpkgs
#    and a second copy of every transitive dependency. `config.lib.mkFlake`
#    reads the flake.nix (not the flake.lock) and resolves every declared
#    input through `getInput`, i.e. recursively, so that nested flakes end up
#    sharing this flake's inputs.
#
# Usage, from any module:
#
#   # Flakes come back evaluated, source trees as `{ outPath = "..."; }`, so
#   # `"${...}"` is the one accessor that works for both.
#   config.lib.getInput "arduino-index"
#   (config.lib.getInput "arduino-index").outPath
#
#   # Inputs of a nested flake are resolved through `getInput` as well.
#   (config.lib.getInput "arduino-nix").overlay
#   (config.lib.mkFlake { path = ./sub/flake; }).packages.${system}.default
{
  pkgs,
  lib,
  config,
  inputs,
  # Niv sources (see `nix/sources.nix`), used as the fallback for inputs the
  # flake does not declare itself.
  niv ? { },
  ...
}:

let
  inherit (builtins)
    attrNames
    isAttrs
    isString
    pathExists
    ;

  describe = names: if names == [ ] then "(none)" else lib.concatStringsSep ", " names;

  # Nix hands `flake = true` inputs over as an evaluated flake: the outputs are
  # spread at the top level and `inputs`/`outputs` are present. `flake = false`
  # inputs are just the fetched tree, an attrset with `outPath`/`narHash` but
  # neither `inputs` nor `outputs`. That absence is the discriminator, since
  # both shapes are string-coercible.
  isFlakeValue = value: isAttrs value && value ? outputs;

  # Reduce a source tree to `{ outPath = ...; }`, whatever shape it came in as.
  asSource =
    value: if isAttrs value then { inherit (value) outPath; } else { outPath = toString value; };

  # Evaluate the flake at `path` as if it had been passed in as an input.
  #
  # The result looks like a real flake input: the flake's outputs are exposed
  # at the top level, plus `outPath`, `inputs` and `outputs`. Only the names and
  # `flake` flags of the declared inputs are used; their `url` values are
  # deliberately ignored so that `getInput` decides where each one comes from.
  #
  # `stack` is internal bookkeeping: the names currently being resolved, so
  # that a cycle turns into an error instead of an endless recursion.
  mkFlake =
    {
      path,
      stack ? [ ],
    }:
    let
      outPath = toString path;
      flakeFile = outPath + "/flake.nix";
    in
    if !(pathExists flakeFile) then
      throw "devshell: ${outPath} is not a flake: no flake.nix found"
    else
      let
        flake = import flakeFile;
        declared = flake.inputs or { };

        # Note that `inputs` is resolved lazily and one attribute at a time, so
        # a flake is only fetched when something actually asks for it.
        inputs' = lib.genAttrs (attrNames declared) (
          name:
          builtins.addErrorContext "while resolving input '${name}' of the flake at ${outPath}" (getInput {
            inherit name stack;
            # `inputs.foo.flake = false` in the nested flake: hand over the
            # source tree instead of an evaluated flake.
            flake = if isAttrs declared.${name} then declared.${name}.flake or true else true;
          })
        );

        outputs = flake.outputs (inputs' // { self = result; });

        result = outputs // {
          inherit outPath outputs;
          inputs = inputs';
          _type = "flake";
        };
      in
      result;

  # Wrap a niv source (a store path) into the same shape as `mkFlake` returns.
  # Sources without a flake.nix (data repositories, for instance) and sources
  # the caller wants as-is (`flake = false`) are returned as `{ outPath = ...; }`.
  fromSource =
    {
      src,
      flake ? true,
      stack ? [ ],
    }:
    let
      outPath = toString src;
    in
    if flake && pathExists (outPath + "/flake.nix") then
      mkFlake {
        path = outPath;
        inherit stack;
      }
    else
      { inherit outPath; };

  # Resolve an input by name.
  #
  # Lookup order:
  #   1. `inputs`: inputs of the top-level flake, as resolved by Nix from
  #      flake.lock. They always win, so overriding a nested flake's input is
  #      just a matter of adding it to this flake's inputs. Their shape is
  #      preserved: `flake = false` inputs stay sources, they are never
  #      evaluated as flakes behind the declaring flake's back.
  #   2. `niv`: the project's niv sources. There is no declaration to consult
  #      here, so a source tree is evaluated as a flake when it contains a
  #      flake.nix, unless the caller passes `flake = false`.
  #
  # `flake` and `stack` are internal, see `mkFlake`.
  getInput =
    arg:
    let
      name =
        if isString arg then
          arg
        else if arg ? name then
          arg.name
        else
          throw "devshell: getInput expects a name or { name = \"...\"; }";

      flake = if isString arg then true else arg.flake or true;
      stack = if isString arg then [ ] else arg.stack or [ ];
    in
    if inputs ? ${name} then
      # `inputs.${name}` is either an evaluated flake or a source tree; Nix
      # already honoured the declaration in this flake.nix. Only downgrade on
      # an explicit request.
      if !flake && isFlakeValue inputs.${name} then asSource inputs.${name} else inputs.${name}
    else if niv ? ${name} then
      if lib.elem name stack then
        throw ''
          devshell: cycle detected while resolving inputs:
            ${lib.concatStringsSep " -> " (stack ++ [ name ])}''
      else
        fromSource {
          inherit flake;
          src = niv.${name};
          stack = stack ++ [ name ];
        }
    else
      throw ''
        devshell: input '${name}' is not available.

        Not an input of this flake: ${describe (attrNames inputs)}
        Not a niv source:          ${describe (attrNames niv)}

        Declare it in the flake's `inputs`, or add it with `niv add`.'';

in
{
  # freestyle
  options.lib = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    internal = true;
    description = ''
      Helper library for this devshell, available as `config.lib`.
    '';
  };

  config.lib = {
    inherit getInput mkFlake;
  };
}
