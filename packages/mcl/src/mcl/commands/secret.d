module mcl.commands.secret;

import std.algorithm : filter, map, each, sort;
import std.array : array, join;
import std.json : JSONValue, toJSON;
import std.file : exists, isDir, dirEntries, SpanMode, mkdirRecurse,
    remove, write, read, deleteme;
import std.path : buildPath, baseName, stripExtension, dirName;
import std.process : environment;
import std.logger : infof, tracef, warningf, errorf;
import std.stdio : writeln;
import std.regex : ctRegex, matchFirst;
import std.string : replace, split, strip, endsWith;

import argparse : AllowedValues, Command, Description, NamedArgument, Placeholder,
    Required, SubCommand, Default, matchCmd;

import sparkles.test_utils.tmpfs : TmpFS;

import mcl.utils.log : errorAndExit;
import mcl.utils.nix : nix;
import mcl.utils.path : rootDir;
import mcl.utils.process : execute, isInPath, spawnProcessInline;
import std.conv : to;

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
    @AllowedValues("nixos", "nixosConfigurations")
    nixosConfigurations,

    @AllowedValues("nix-darwin", "darwinConfigurations")
    darwinConfigurations,
}

@(Command("secret")
    .Description("Manage age-encrypted secrets for NixOS machines"))
struct SecretArgs
{
    @(NamedArgument(["machine", "m"])
        .Placeholder("NAME")
        .Description("Machine for which to manage secrets"))
    string machine;

    @(NamedArgument(["configuration-type"])
        .Placeholder("TYPE")
        .Description("Type of configurations, either `nixos`/`nixosConfigurations` or `nix-darwin`/`darwinConfigurations`"))
    ConfigurationType configurationType = ConfigurationType.nixosConfigurations;

    @(NamedArgument(["vm"])
        .Description("Use the vmVariant configuration"))
    bool vm;

    @(NamedArgument(["extra-nix-option"])
        .Description("Extra options to pass to nix commands (can be specified multiple times)")
        .Placeholder("OPTION"))
    string[] extraNixOptions;

    @(NamedArgument(["identity", "i"])
        .Placeholder("PATH")
        .Description("Age identity file to use for decryption"))
    string identity;

    SubCommand!(
        SecretEditArgs,
        SecretReEncryptArgs,
        SecretReEncryptAllArgs,
        SecretListArgs,
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

@(Command("list")
    .Description("List services and their secrets for a machine"))
struct SecretListArgs
{
    @(NamedArgument(["json"])
        .Description("Output as JSON"))
    bool json;

    @(NamedArgument(["include-vms"])
        .Description("Include VM configurations (VMs are hidden by default)"))
    bool includeVMs;
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
        (SecretListArgs a) => secretList(args, a),
        (UnknownCommandArgs _) => unknownCommand(),
    );
}

// =============================================================================
// Subcommand Handlers
// =============================================================================

private int secretEdit(SecretArgs common, SecretEditArgs args)
{
    requireMachine(common);
    validateVmFlag(common.vm, common.configurationType);

    auto tmpfs = TmpFS.create("mcl-secret-identity-keys");
    const confAttr = common.configurationType.to!string;
    auto info = resolveServiceInfo(common, confAttr, args.service);

    auto secretsFolder = args.secretsFolder
        ? args.secretsFolder
        : common.vm
            ? DEFAULT_VM_SECRETS_PATH ~ args.service
            : info.configPath.buildPath("secrets", args.service);

    auto secretFile = secretsFolder.buildPath(args.secret ~ ".age");
    editSecret(secretFile, info.recipients, resolveIdentity(common.identity, tmpfs));
    return 0;
}

private int secretReEncrypt(SecretArgs common, SecretReEncryptArgs args)
{
    requireMachine(common);
    validateVmFlag(common.vm, common.configurationType);

    auto tmpfs = TmpFS.create("mcl-secret-identity-keys");
    const confAttr = common.configurationType.to!string;
    auto info = resolveServiceInfo(common, confAttr, args.service);

    auto secretsFolder = args.secretsFolder.length > 0
        ? args.secretsFolder
        : common.vm
            ? DEFAULT_VM_SECRETS_PATH ~ args.service
            : info.configPath.buildPath("secrets", args.service);

    reEncryptFolder(secretsFolder, info.recipients, resolveIdentity(common.identity, tmpfs));
    return 0;
}

private int secretReEncryptAll(SecretArgs common, SecretReEncryptAllArgs args)
{
    requireMachine(common);
    validateVmFlag(common.vm, common.configurationType);

    auto tmpfs = TmpFS.create("mcl-secret-identity-keys");
    const confAttr = common.configurationType.to!string;
    auto allInfo = resolveAllServicesInfo(common, confAttr);
    auto machineFolder = args.configPath.length > 0
        ? args.configPath
        : allInfo.configPath;
    auto identityArgs = resolveIdentity(common.identity, tmpfs);

    foreach (service, recipients; allInfo.serviceRecipients)
    {
        writeln("Re-encrypting secrets for service ", service);
        auto secretsFolder = common.vm
            ? DEFAULT_VM_SECRETS_PATH ~ service
            : machineFolder.buildPath("secrets", service);

        reEncryptFolder(secretsFolder, recipients, identityArgs);
    }

    return 0;
}

private int secretList(SecretArgs common, SecretListArgs args)
{
    const confAttr = common.configurationType.to!string;

    if (common.machine.length > 0)
    {
        auto info = resolveListInfo(common, confAttr);

        if (args.json)
        {
            JSONValue j;
            foreach (svc, secrets; info.serviceSecrets)
                j[svc] = JSONValue(secrets.dup.sort.array);
            writeln(j.toJSON(pretty: true));
        }
        else
        {
            foreach (svc; info.serviceSecrets.keys.dup.sort.array)
            {
                writeln(svc ~ ":");
                foreach (secret; info.serviceSecrets[svc].dup.sort.array)
                    writeln("  - " ~ secret);
            }
        }
    }
    else
    {
        auto info = resolveAllMachinesListInfo(common, args, confAttr);

        if (args.json)
        {
            JSONValue j;
            foreach (machine, ms; info.machines)
            {
                JSONValue ms_j;
                foreach (svc, secrets; ms.serviceSecrets)
                {
                    // Check if this is an error marker
                    if (svc == "__ERROR__")
                        ms_j["__error__"] = JSONValue("See stderr for details");
                    else
                        ms_j[svc] = JSONValue(secrets.dup.sort.array);
                }
                j[machine] = ms_j;
            }
            writeln(j.toJSON(pretty: true));
        }
        else
        {
            foreach (machine; info.machines.keys.dup.sort.array)
            {
                writeln(machine ~ ":");
                bool hasError = false;
                foreach (svc; info.machines[machine].serviceSecrets.keys.dup.sort.array)
                {
                    // Check if this is an error marker
                    if (svc == "__ERROR__")
                    {
                        writeln("  ERROR (see stderr for details)");
                        hasError = true;
                    }
                    else
                    {
                        writeln("  " ~ svc ~ ":");
                        foreach (secret; info.machines[machine].serviceSecrets[svc].dup.sort.array)
                            writeln("    - " ~ secret);
                    }
                }
            }
        }
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
    tracef("editSecret: secretFile=%s, recipients=%s, identityArgs=%s",
        secretFile, recipients, identityArgs);

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
        infof("Decrypting existing secret: %s", secretFile);
        auto decryptCmd = ["age", "--decrypt"] ~ identityArgs ~ ["-o", cleartextFile, "--", secretFile];
        spawnProcessInline(decryptCmd);
    }
    else
    {
        infof("Secret file does not exist yet, creating new: %s", secretFile);
    }

    // Open editor
    auto editor = environment.get("EDITOR", "vim");
    infof("Opening editor: %s %s", editor, cleartextFile);
    spawnProcessInline([editor, cleartextFile]);

    if (!cleartextFile.exists)
    {
        writeln("No file saved, skipping encryption.");
        return;
    }

    auto cleartextData = read(cleartextFile);
    tracef("Cleartext data size: %s bytes", cleartextData.length);

    // Ensure output directory exists
    auto outputDir = secretFile.dirName;
    if (!outputDir.exists)
    {
        infof("Creating output directory: %s", outputDir);
        mkdirRecurse(outputDir);
    }

    // Encrypt with all recipients via stdin to avoid cleartext in process list (ps)
    import std.process : pipeProcess, wait, Redirect;
    auto encryptCmd = ["age", "--encrypt", "--armor"]
        ~ recipientArgs(recipients)
        ~ ["-o", secretFile]
        ~ ["-"];  // Read from stdin
    infof("Encrypting to %s with %s recipient(s)", secretFile, recipients.length);
    tracef("Encrypt command: %-(%s %)", encryptCmd);
    auto pipes = pipeProcess(encryptCmd, Redirect.stdin | Redirect.stdout | Redirect.stderr);
    pipes.stdin.rawWrite(cleartextData);
    pipes.stdin.close();

    auto stdoutOutput = pipes.stdout.byLine().join("\n").to!string;
    auto stderrOutput = pipes.stderr.byLine().join("\n").to!string;
    pipes.stdout.close();
    pipes.stderr.close();
    auto status = wait(pipes.pid);

    if (status != 0)
    {
        errorf("Encryption failed (exit code %s)\nstdout: %s\nstderr: %s",
            status, stdoutOutput, stderrOutput);
        errorAndExit("Encryption failed (exit code " ~ status.to!string ~ "): " ~ stderrOutput);
    }

    tracef("Encryption stdout: %s", stdoutOutput);
    tracef("Encryption stderr: %s", stderrOutput);
    infof("Successfully encrypted secret to %s", secretFile);
}

private void reEncryptFolder(string secretsFolder, string[] recipients, string[] identityArgs)
{
    tracef("reEncryptFolder: secretsFolder=%s, recipients=%s, identityArgs=%s",
        secretsFolder, recipients, identityArgs);

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

    infof("Re-encrypting %s file(s) in %s", ageFiles.length, secretsFolder);

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
        infof("Decrypting %s", ageFile);
        auto decryptCmd = ["age", "--decrypt"] ~ identityArgs ~ ["-o", cleartextFile, "--", ageFile];
        spawnProcessInline(decryptCmd);

        // Re-encrypt via stdin to avoid cleartext in process list (ps)
        import std.process : pipeProcess, wait, Redirect;
        auto cleartextData = read(cleartextFile);
        auto encryptCmd = ["age", "--encrypt", "--armor"]
            ~ recipientArgs(recipients)
            ~ ["-o", ageFile]
            ~ ["-"];  // Read from stdin
        tracef("Re-encrypt command: %-(%s %)", encryptCmd);
        auto pipes = pipeProcess(encryptCmd, Redirect.stdin | Redirect.stdout | Redirect.stderr);
        pipes.stdin.rawWrite(cleartextData);
        pipes.stdin.close();

        auto stdoutOutput = pipes.stdout.byLine().join("\n").to!string;
        auto stderrOutput = pipes.stderr.byLine().join("\n").to!string;
        pipes.stdout.close();
        pipes.stderr.close();
        auto status = wait(pipes.pid);

        if (status != 0)
        {
            errorf("Re-encryption of %s failed (exit code %s)\nstdout: %s\nstderr: %s",
                ageFile, status, stdoutOutput, stderrOutput);
            errorAndExit("Re-encryption failed (exit code " ~ status.to!string ~ "): " ~ stderrOutput);
        }

        tracef("Re-encryption stdout: %s", stdoutOutput);
        tracef("Re-encryption stderr: %s", stderrOutput);
    }

    infof("Successfully re-encrypted %s file(s)", ageFiles.length);
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

    // Try age-plugin-yubikey: query for hardware-backed identities
    identityArgs = resolveYubikeyIdentities(tmpfs);
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

private enum yubikeyIdentityPattern = ctRegex!(`^AGE-PLUGIN-YUBIKEY-[0-9A-Z]+$`);

private string[] resolveYubikeyIdentities(ref TmpFS tmpfs)
{
    // Check if age-plugin-yubikey is available on PATH before executing
    if (!isInPath("age-plugin-yubikey"))
    {
        infof("age-plugin-yubikey not found in PATH, skipping YubiKey identity resolution");
        return [];
    }

    string[] identityArgs;

    try
    {
        auto output = execute(["age-plugin-yubikey", "-i"], printCommand: false);
        auto identities = output
            .split("\n")
            .map!strip
            .filter!(l => !l.matchFirst(yubikeyIdentityPattern).empty)
            .array;

        foreach (identity; identities)
        {
            auto tmpPath = tmpfs.writeFile(identity);
            infof("Using YubiKey identity: %s", identity);
            identityArgs ~= ["-i", tmpPath];
        }
    }
    catch (Exception e)
    {
        infof("age-plugin-yubikey execution failed: %s", e.msg);
    }

    return identityArgs;
}

// =============================================================================
// Helpers
// =============================================================================

private void requireMachine(SecretArgs common)
{
    if (common.machine.length == 0)
        errorAndExit("--machine is required for this subcommand.");
}

private void validateVmFlag(bool vm, ConfigurationType configurationType)
{
    if (vm && configurationType != ConfigurationType.nixosConfigurations)
        errorAndExit("Cannot use `vm` with `configuration-type` " ~ configurationType.to!string);
}

// JSON parsing structs for mcl.secrets
private struct SecretFileInfo
{
    string file;
    string group;
    string mode;
    string name;
    string owner;
    string path;
    bool symlink;
}

private struct MachineServiceConfig
{
    string encryptedSecretDir;
    string[] extraKeys;
    string[] recipients;
    SecretFileInfo[string] secrets;
}

private struct MachineSecretsConfig
{
    string[] extraKeys;
    MachineServiceConfig[string] services;
}

// Output structures for list operations
private struct MachineServiceSecrets
{
    string[][string] serviceSecrets;
    bool isVM;  // true if this is a debug VM
}

private struct AllMachinesListInfo
{
    MachineServiceSecrets[string] machines;
}

private struct ServiceInfo
{
    string configPath;
    string[] recipients;
}

/// Resolves configPath and recipients for a single service in one nix eval.
private ServiceInfo resolveServiceInfo(SecretArgs common, string confAttr, string service)
{
    import std.json : JSONValue;

    auto configBase = common.vm
        ? rootDir ~ "#nixosConfigurations." ~ common.machine
            ~ "-vm.config.virtualisation.vmVariant"
        : rootDir ~ "#" ~ confAttr ~ "." ~ common.machine ~ ".config";

    auto json = nix().eval!JSONValue(configBase, common.extraNixOptions ~ [
        "--apply", "c: { configPath = c.mcl.host-info.configPath; "
            ~ "recipients = c.mcl.secrets.services." ~ service ~ ".recipients; }"
    ]);

    return ServiceInfo(
        configPath: json["configPath"].str,
        recipients: json["recipients"].array.map!(v => v.str).array,
    );
}

private struct AllServicesInfo
{
    string configPath;
    string[][string] serviceRecipients;
}

/// Resolves configPath and recipients for all services in one nix eval.
private AllServicesInfo resolveAllServicesInfo(SecretArgs common, string confAttr)
{
    import std.json : JSONValue;

    auto configBase = common.vm
        ? rootDir ~ "#nixosConfigurations." ~ common.machine
            ~ "-vm.config.virtualisation.vmVariant"
        : rootDir ~ "#" ~ confAttr ~ "." ~ common.machine ~ ".config";

    auto json = nix().eval!JSONValue(configBase, common.extraNixOptions ~ [
        "--apply", "c: { configPath = c.mcl.host-info.configPath; "
            ~ "services = builtins.mapAttrs (_: s: s.recipients) c.mcl.secrets.services; }"
    ]);

    string[][string] serviceRecipients;
    foreach (name, val; json["services"].object)
        serviceRecipients[name] = val.array.map!(v => v.str).array;

    return AllServicesInfo(
        configPath: json["configPath"].str,
        serviceRecipients: serviceRecipients,
    );
}

/// Resolves list info for a single machine by evaluating mcl.secrets and mcl.host-info.
private MachineServiceSecrets resolveListInfo(SecretArgs common, string confAttr)
{
    import mcl.utils.json : fromJSON;
    import std.json : JSONValue;

    auto configBase = common.vm
        ? rootDir ~ "#nixosConfigurations." ~ common.machine
            ~ "-vm.config.virtualisation.vmVariant.mcl.secrets"
        : rootDir ~ "#" ~ confAttr ~ "." ~ common.machine ~ ".config.mcl.secrets";

    auto secretsConfig = nix()
        .eval!JSONValue(configBase, common.extraNixOptions)
        .fromJSON!MachineSecretsConfig;

    string[][string] serviceSecrets;
    foreach (name, svc; secretsConfig.services)
        serviceSecrets[name] = svc.secrets.keys.dup.sort.array;

    // Determine if this is a VM based on machine name convention (machines ending in "-vm")
    return MachineServiceSecrets(serviceSecrets: serviceSecrets, isVM: common.machine.endsWith("-vm"));
}

/// Resolves list info for all machines using --apply to avoid heavy eval.
/// Falls back to per-machine evaluation if the bulk eval fails, with errors logged to stderr.
/// Filters out VMs unless --include-vms is specified.
private AllMachinesListInfo resolveAllMachinesListInfo(
    SecretArgs common,
    SecretListArgs listArgs,
    string confAttr
)
{
    auto flakeAttr = rootDir ~ "#" ~ confAttr;

    // Try bulk evaluation first
    try
    {
        auto json = nix().eval!JSONValue(flakeAttr, common.extraNixOptions ~ [
            "--apply",
            "cfgs: builtins.mapAttrs (_: m:"
                ~ " builtins.mapAttrs (_: s: builtins.attrNames s.secrets)"
                ~ " m.config.mcl.secrets.services) cfgs"
        ]);

        AllMachinesListInfo result;
        foreach (machine, services; json.object)
        {
            // Skip VMs unless --include-vms is specified
            if (machine.endsWith("-vm") && !listArgs.includeVMs)
                continue;

            string[][string] svcMap;
            foreach (svc, secrets; services.object)
                svcMap[svc] = secrets.array.map!(v => v.str).array;
            result.machines[machine] = MachineServiceSecrets(
                serviceSecrets: svcMap,
                isVM: machine.endsWith("-vm")
            );
        }

        return result;
    }
    catch (Exception e)
    {
        // Bulk eval failed, fall back to per-machine evaluation
        warningf("Bulk evaluation of all machines failed, evaluating machines individually");
        return resolveAllMachinesListInfoFallback(common, listArgs, confAttr);
    }
}

/// Fallback to evaluate machines one at a time when bulk eval fails.
/// Logs errors to stderr for failed machines and returns partial results with ERROR markers.
private AllMachinesListInfo resolveAllMachinesListInfoFallback(
    SecretArgs common,
    SecretListArgs listArgs,
    string confAttr
)
{
    auto flakeAttr = rootDir ~ "#" ~ confAttr;

    // Get list of all available machines using --apply to extract attribute names
    auto machineListJson = nix().eval!JSONValue(
        flakeAttr,
        common.extraNixOptions ~ [
            "--apply",
            "cfgs: builtins.attrNames cfgs"
        ]
    );

    string[] machines;
    foreach (machine; machineListJson.array)
        machines ~= machine.str;

    AllMachinesListInfo result;
    foreach (machine; machines.dup.sort.array)
    {
        // Skip VMs unless --include-vms is specified
        bool isVM = machine.endsWith("-vm");
        if (isVM && !listArgs.includeVMs)
            continue;

        try
        {
            auto singleMachineResult = resolveListInfo(
                SecretArgs(
                    machine: machine,
                    configurationType: common.configurationType,
                    vm: common.vm,
                    extraNixOptions: common.extraNixOptions,
                    identity: common.identity,
                    cmd: common.cmd
                ),
                confAttr
            );
            result.machines[machine] = singleMachineResult;
        }
        catch (Exception e)
        {
            errorf("Failed to evaluate machine '%s': %s", machine, e.msg);
            // Add ERROR marker for this machine
            result.machines[machine] = MachineServiceSecrets(
                serviceSecrets: ["__ERROR__": ["See stderr for details"]],
                isVM: isVM
            );
        }
    }

    return result;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

@("ConfigurationType.to!string maps nixosConfigurations")
unittest
{
    import std.conv : to;
    assert(ConfigurationType.nixosConfigurations.to!string == "nixosConfigurations");
}

@("ConfigurationType.to!string maps darwinConfigurations")
unittest
{
    import std.conv : to;
    assert(ConfigurationType.darwinConfigurations.to!string == "darwinConfigurations");
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
