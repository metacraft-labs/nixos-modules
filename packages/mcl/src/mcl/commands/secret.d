module mcl.commands.secret;

import std.algorithm : filter, map, each;
import std.array : array, join;
import std.file : exists, isDir, dirEntries, SpanMode, mkdirRecurse,
    remove, write, read, deleteme;
import std.path : buildPath, baseName, stripExtension, dirName;
import std.process : environment;
import std.logger : infof, warningf;
import std.stdio : writeln;
import std.string : replace, split, strip, endsWith;

import argparse : Command, Description, NamedArgument, Placeholder, Required,
    SubCommand, Default, matchCmd;

import sparkles.test_utils.tmpfs : TmpFS;

import mcl.utils.log : errorAndExit;
import mcl.utils.nix : nix;
import mcl.utils.process : execute, spawnProcessInline;
import mcl.utils.string : enumToString, StringRepresentation;

// =============================================================================
// Constants
// =============================================================================

/// Default secrets directory path for VM configurations.
/// Used when the `--vm` flag is specified, pointing to the default VM
/// configuration's secrets folder relative to the repository root.
/// NOTE: This must be kept in sync with the `secretDir` variable in `modules/secrets.nix`.
enum DEFAULT_VM_SECRETS_PATH = "./modules/default-vm-config/secrets/";

// =============================================================================
// CLI Argument Definitions
// =============================================================================

enum ConfigurationType
{
    @StringRepresentation("nixosConfigurations") nixos,
    @StringRepresentation("darwinConfigurations") nix_darwin,
}

@(Command("secret")
    .Description("Manage age-encrypted secrets for NixOS machines"))
struct SecretArgs
{
    @(NamedArgument(["machine", "m"])
        .Required()
        .Placeholder("NAME")
        .Description("Machine for which to manage secrets"))
    string machine;

    @(NamedArgument(["configuration-type"])
        .Placeholder("TYPE")
        .Description("Type of configurations, either `nixos` or `nix-darwin`"))
    ConfigurationType configurationType = ConfigurationType.nixos;

    @(NamedArgument(["vm"])
        .Description("Use the vmVariant configuration"))
    bool vm;

    @(NamedArgument(["extra-nix-option"])
        .Description("Extra options to pass to nix commands (can be specified multiple times)")
        .Placeholder("OPTION"))
    string[] extraNixOptions;

    @(NamedArgument(["identity", "i"])
        .Placeholder("PATH")
        .Description("SSH private key to use for decryption"))
    string identity;

    SubCommand!(
        SecretEditArgs,
        SecretReEncryptArgs,
        SecretReEncryptAllArgs,
        Default!UnknownCommandArgs
    ) cmd;
}

@(Command(" ").Description(" "))
struct UnknownCommandArgs { }

@(Command("edit")
    .Description("Encrypt or edit a single secret for a service"))
struct SecretEditArgs
{
    @(NamedArgument(["service"])
        .Required()
        .Placeholder("NAME")
        .Description("Service for which to manage secrets"))
    string service;

    @(NamedArgument(["secret"])
        .Required()
        .Placeholder("NAME")
        .Description("Secret you want to encrypt"))
    string secret;

    @(NamedArgument(["secrets-folder"])
        .Placeholder("PATH")
        .Description("Specifies the location where secrets are saved"))
    string secretsFolder;
}

@(Command("re-encrypt")
    .Description("Re-encrypt all secrets for a single service"))
struct SecretReEncryptArgs
{
    @(NamedArgument(["service"])
        .Required()
        .Placeholder("NAME")
        .Description("Service for which to re-encrypt secrets"))
    string service;

    @(NamedArgument(["secrets-folder"])
        .Placeholder("PATH")
        .Description("Specifies the location where secrets are saved"))
    string secretsFolder;
}

@(Command("re-encrypt-all")
    .Description("Re-encrypt all secrets for all services on a machine"))
struct SecretReEncryptAllArgs
{
    @(NamedArgument(["config-path"])
        .Placeholder("PATH")
        .Description("Override the configPath from NixOS configuration"))
    string configPath;
}

// =============================================================================
// Public Entry Point
// =============================================================================

export int secret(SecretArgs args)
{
    return args.cmd.matchCmd!(
        (SecretEditArgs a) => secretEdit(args, a),
        (SecretReEncryptArgs a) => secretReEncrypt(args, a),
        (SecretReEncryptAllArgs a) => secretReEncryptAll(args, a),
        (UnknownCommandArgs _) => unknownCommand(),
    );
}

// =============================================================================
// Subcommand Handlers
// =============================================================================

private int secretEdit(SecretArgs common, SecretEditArgs args)
{
    validateVmFlag(common.vm, common.configurationType);

    auto tmpfs = TmpFS.create("mcl-secret-agent-keys");
    const confAttr = common.configurationType.enumToString;
    auto machineFolder = resolveMachineFolder(common.machine, confAttr, common.extraNixOptions);
    auto recipients = resolveRecipients(common, confAttr, args.service);

    auto secretsFolder = args.secretsFolder
        ? args.secretsFolder
        : common.vm
            ? DEFAULT_VM_SECRETS_PATH ~ args.service
            : machineFolder.buildPath("secrets", args.service);

    auto secretFile = secretsFolder.buildPath(args.secret ~ ".age");
    editSecret(secretFile, recipients, resolveIdentity(common.identity, tmpfs));
    return 0;
}

private int secretReEncrypt(SecretArgs common, SecretReEncryptArgs args)
{
    validateVmFlag(common.vm, common.configurationType);

    auto tmpfs = TmpFS.create("mcl-secret-agent-keys");
    const confAttr = common.configurationType.enumToString;
    auto machineFolder = resolveMachineFolder(common.machine, confAttr, common.extraNixOptions);
    auto recipients = resolveRecipients(common, confAttr, args.service);

    auto secretsFolder = args.secretsFolder.length > 0
        ? args.secretsFolder
        : common.vm
            ? DEFAULT_VM_SECRETS_PATH ~ args.service
            : machineFolder.buildPath("secrets", args.service);

    reEncryptFolder(secretsFolder, recipients, resolveIdentity(common.identity, tmpfs));
    return 0;
}

private int secretReEncryptAll(SecretArgs common, SecretReEncryptAllArgs args)
{
    validateVmFlag(common.vm, common.configurationType);

    auto tmpfs = TmpFS.create("mcl-secret-agent-keys");
    const confAttr = common.configurationType.enumToString;
    auto machineFolder = args.configPath.length > 0
        ? args.configPath
        : resolveMachineFolder(common.machine, confAttr, common.extraNixOptions);
    auto identityArgs = resolveIdentity(common.identity, tmpfs);

    auto services = nixEvalAttrNames(
        common.extraNixOptions,
        ".#" ~ confAttr ~ "." ~ common.machine ~ ".config.mcl.secrets.services"
    );

    foreach (service; services)
    {
        writeln("Re-encrypting secrets for service ", service);
        auto recipients = resolveRecipients(common, confAttr, service);
        auto secretsFolder = common.vm
            ? DEFAULT_VM_SECRETS_PATH ~ service
            : machineFolder.buildPath("secrets", service);

        reEncryptFolder(secretsFolder, recipients, identityArgs);
    }

    return 0;
}

private int unknownCommand()
{
    errorAndExit("Unknown command. Use --help for a list of available commands.");
    assert(0);
}

// =============================================================================
// Age Operations
// =============================================================================

private void editSecret(string secretFile, string[] recipients, string[] identityArgs)
{
    if (recipients.length == 0)
        errorAndExit("No recipients found for encryption.");

    auto cleartextFile = deleteme;
    scope (exit)
    {
        if (cleartextFile.exists)
            remove(cleartextFile);
    }

    // Decrypt existing file if present
    if (secretFile.exists)
    {
        auto decryptCmd = ["age", "--decrypt"] ~ identityArgs ~ ["-o", cleartextFile, "--", secretFile];
        spawnProcessInline(decryptCmd);
    }

    // Open editor
    auto editor = environment.get("EDITOR", "vim");
    spawnProcessInline([editor, cleartextFile]);

    if (!cleartextFile.exists)
    {
        writeln("No file saved, skipping encryption.");
        return;
    }

    // Ensure output directory exists
    auto outputDir = secretFile.dirName;
    if (!outputDir.exists)
        mkdirRecurse(outputDir);

    // Encrypt with all recipients via stdin to avoid cleartext in process list (ps)
    import std.process : pipeProcess, wait, Redirect;
    auto cleartextData = read(cleartextFile);
    auto encryptCmd = ["age", "--encrypt", "--armor"]
        ~ recipientArgs(recipients)
        ~ ["-o", secretFile]
        ~ ["-"];  // Read from stdin
    auto pipes = pipeProcess(encryptCmd, Redirect.stdin | Redirect.stdout | Redirect.stderr);
    pipes.stdin.rawWrite(cleartextData);
    pipes.stdin.close();
    pipes.stdout.close();
    pipes.stderr.close();
    auto status = wait(pipes.pid);
    if (status != 0)
        errorAndExit("Encryption failed");
}

private void reEncryptFolder(string secretsFolder, string[] recipients, string[] identityArgs)
{
    if (!secretsFolder.exists)
        errorAndExit("Secrets folder does not exist: " ~ secretsFolder);

    if (recipients.length == 0)
        errorAndExit("No recipients found for encryption.");

    auto ageFiles = dirEntries(secretsFolder, "*.age", SpanMode.shallow)
        .map!(e => e.name)
        .array;

    if (ageFiles.length == 0)
    {
        writeln("No .age files found in ", secretsFolder);
        return;
    }

    foreach (ageFile; ageFiles)
    {
        auto secretName = ageFile.baseName.stripExtension;
        writeln("  Re-encrypting ", secretName);

        auto cleartextFile = deleteme;
        scope (exit)
        {
            if (cleartextFile.exists)
                remove(cleartextFile);
        }

        // Decrypt
        auto decryptCmd = ["age", "--decrypt"] ~ identityArgs ~ ["-o", cleartextFile, "--", ageFile];
        spawnProcessInline(decryptCmd);

        // Re-encrypt via stdin to avoid cleartext in process list (ps)
        import std.process : pipeProcess, wait, Redirect;
        auto cleartextData = read(cleartextFile);
        auto encryptCmd = ["age", "--encrypt", "--armor"]
            ~ recipientArgs(recipients)
            ~ ["-o", ageFile]
            ~ ["-"];  // Read from stdin
        auto pipes = pipeProcess(encryptCmd, Redirect.stdin | Redirect.stdout | Redirect.stderr);
        pipes.stdin.rawWrite(cleartextData);
        pipes.stdin.close();
        pipes.stdout.close();
        pipes.stderr.close();
        auto status = wait(pipes.pid);
        if (status != 0)
            errorAndExit("Re-encryption failed");
    }
}

// =============================================================================
// Recipient Resolution
// =============================================================================

private string[] recipientArgs(string[] recipients)
{
    return recipients
        .map!(r => ["-r", r])
        .join
        .array;
}

private string[] resolveIdentity(string identityPath, ref TmpFS tmpfs)
{
    if (identityPath.length > 0)
    {
        if (!identityPath.exists)
            warningf("Specified identity file does not exist: %s", identityPath);
        return ["-i", identityPath];
    }

    string[] identityArgs;

    // Try ssh-agent first: if SSH_AUTH_SOCK is set, ask the agent for
    // public keys and write each to a temp file so age can use the agent
    // for decryption.
    auto authSock = environment.get("SSH_AUTH_SOCK", "");
    if (authSock.length > 0)
    {
        try
        {
            auto agentKeys = execute(["ssh-add", "-L"], false);
            foreach (line; agentKeys.split("\n").filter!(l => l.length > 0))
            {
                auto tmpPath = tmpfs.writeFile(line);
                infof("Using ssh-agent identity: %s", tmpPath);
                identityArgs ~= ["-i", tmpPath];
            }
        }
        catch (Exception e)
        {
            warningf("Failed to list ssh-agent keys: %s", e.msg);
        }
    }

    if (identityArgs.length > 0)
        return identityArgs;

    // Fall back to well-known SSH key paths
    auto home = environment.get("HOME", "");
    if (home.length > 0)
    {
        auto ed25519 = home.buildPath(".ssh", "id_ed25519");
        auto rsa = home.buildPath(".ssh", "id_rsa");

        if (ed25519.exists)
        {
            infof("Using auto-discovered identity: %s", ed25519);
            identityArgs ~= ["-i", ed25519];
        }
        if (rsa.exists)
        {
            infof("Using auto-discovered identity: %s", rsa);
            identityArgs ~= ["-i", rsa];
        }
    }
    return identityArgs;
}

// =============================================================================
// Helpers
// =============================================================================

private void validateVmFlag(bool vm, ConfigurationType configurationType)
{
    if (vm && configurationType != ConfigurationType.nixos)
        errorAndExit("Cannot use `vm` with `configuration-type` " ~ configurationType.enumToString);
}

private string resolveMachineFolder(string machine, string confAttr, string[] extraNixOptions)
{
    import std.json : JSONValue;

    // Use --json to get clean string output without nix store path prefix
    auto json = nix().eval!JSONValue(".#" ~ confAttr ~ "." ~ machine ~ ".config.mcl.host-info.configPath", extraNixOptions);
    return json.str;
}

private string[] resolveRecipients(SecretArgs common, string confAttr, string service)
{
    import std.json : JSONValue;

    auto configBase = common.vm
        ? ".#nixosConfigurations." ~ common.machine
            ~ "-vm.config.virtualisation.vmVariant"
        : ".#" ~ confAttr ~ "." ~ common.machine ~ ".config";

    auto json = nix().eval!JSONValue(
        configBase ~ ".mcl.secrets.services." ~ service ~ ".recipients",
        common.extraNixOptions);

    return json.array.map!(v => v.str).array;
}

private string[] nixEvalAttrNames(string[] extraNixOptions, string path)
{
    import std.json : JSONValue;

    auto json = nix().eval!JSONValue(path, extraNixOptions ~ ["--apply", "builtins.attrNames"]);
    return json.array.map!(v => v.str).array;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

@("ConfigurationType.enumToString maps nixos")
unittest
{
    assert(ConfigurationType.nixos.enumToString == "nixosConfigurations");
}

@("ConfigurationType.enumToString maps nix-darwin")
unittest
{
    assert(ConfigurationType.nix_darwin.enumToString == "darwinConfigurations");
}

@("recipientArgs builds correct args")
unittest
{
    assert(recipientArgs(["key1", "key2"]) == ["-r", "key1", "-r", "key2"]);
}

@("recipientArgs handles single key")
unittest
{
    assert(recipientArgs(["key1"]) == ["-r", "key1"]);
}
