module mcl.commands.machine;

import std;

import argparse : Command, Description, NamedArgument, PositionalArgument, Placeholder, SubCommand, Default, matchCmd;

import mcl.utils.log : prompt;
import mcl.utils.process : execute;
import mcl.utils.nix : nix, toNix, Literal, mkDefault;
import mcl.utils.json : toJSON, fromJSON;
import mcl.utils.array : uniqArrays;
import mcl.commands.host_info: Info;

enum MachineType
{
    desktop = 1,
    server = 2,
    container = 3
}

enum HostType
{
    notebook,
    desktop,
    server
}

enum PartitioningPreset
{
    zfs,
    zfs_legacy,
    ext4
}

enum ZpoolMode
{
    mirror,
    raidz1,
    raidz2,
    raidz3,
    stripe
}

struct User {
    string userName;
    UserInfo userInfo;
    EmailInfo emailInfo;
}

struct UserInfo
{
    string description;
    string[] extraGroups;
    string hashedPassword;
    string[] sshKeys;
}

struct EmailInfo
{
    string workEmail;
    string personalEmail;
    string gitlabUsername;
    string descriptionBG;
    string[] emailAliases;
    string githubUsername;
    string discordUsername;
}

string[] getExistingUsers()
{
    return dirEntries("users", SpanMode.shallow).map!(a => a.name.replace("users/", "")).array;
}

User getUser(string userName)
{
    auto userJson = nix.eval!JSONValue("users/" ~ userName ~ "/user-info.nix", ["--file"]);
    User user;
    user.userName = userName;
    user.userInfo.description = userJson["userInfo"]["description"].str;
    user.userInfo.extraGroups = userJson["userInfo"]["extraGroups"].array.map!(a => a.str).array;
    user.userInfo.hashedPassword = userJson["userInfo"]["hashedPassword"].str;
    user.userInfo.sshKeys = userJson["userInfo"]["openssh"]["authorizedKeys"]["keys"].array.map!(a => a.str).array;
    user.emailInfo.personalEmail = ("personalEmail" in userJson["emailInfo"].object) ? userJson["emailInfo"]["personalEmail"].str : "";
    user.emailInfo.workEmail = ("workEmail" in userJson["emailInfo"].object) ? userJson["emailInfo"]["workEmail"].str : user.emailInfo.personalEmail;
    user.emailInfo.gitlabUsername = ("gitlabUsername" in userJson["emailInfo"].object) ? userJson["emailInfo"]["gitlabUsername"].str : "";
    user.emailInfo.descriptionBG = ("descriptionBG" in userJson["emailInfo"].object) ? userJson["emailInfo"]["descriptionBG"].str : "";
    user.emailInfo.emailAliases = ("emailAliases" in userJson["emailInfo"].object) ? userJson["emailInfo"]["emailAliases"].array.map!(a => a.str).array : [];
    user.emailInfo.githubUsername = ("githubUsername" in userJson["emailInfo"].object) ? userJson["emailInfo"]["githubUsername"].str : "";
    user.emailInfo.discordUsername = ("discordUsername" in userJson["emailInfo"].object) ? userJson["emailInfo"]["discordUsername"].str : "";
    return user;
}

void createUserDir(User user)
{
    mkdirRecurse("users/" ~ user.userName);
    string userNix = user.toNix;
    std.file.write("users/" ~ user.userName ~ "/user-info.nix", userNix);
    execute(["alejandra", "users/" ~ user.userName ~ "/user-info.nix"], false);
    string gitConfig = generateGitConfig(user);
    std.file.write("users/" ~ user.userName ~ "/.gitconfig", gitConfig);

    mkdirRecurse("users/" ~ user.userName ~ "/home-desktop");
    string homeDesktop = generateHomeDesktop();
    std.file.write("users/" ~ user.userName ~ "/home-desktop/default.nix", homeDesktop);
    execute(["alejandra", "users/" ~ user.userName ~ "/home-desktop/default.nix"], false);
    mkdirRecurse("users/" ~ user.userName ~ "/home-server");
    string homeServer = generateHomeServer();
    std.file.write("users/" ~ user.userName ~ "/home-server/default.nix", homeServer);
    execute(["alejandra", "users/" ~ user.userName ~ "/home-server/default.nix"], false);
}

string generateHomeServer() {
    string homeServer = "{pkgs, ...}: {\n";
    homeServer ~= "  home.packages = with pkgs; [\n";
    homeServer ~= "  ];\n";
    homeServer ~= "}\n";
    return homeServer;
}

string generateHomeDesktop() {
    string homeDesktop = "{pkgs, ...}: {\n";
    homeDesktop ~= "  imports = [\n";
    homeDesktop ~= "    ../home-server\n";
    homeDesktop ~= "  ];\n";
    homeDesktop ~= "  home.packages = with pkgs; [\n";
    homeDesktop ~= "  ];\n";
    homeDesktop ~= "}\n";
    return homeDesktop;
}

string generateGitConfig(User user) {
    string gitConfig = "[user]\n";
    gitConfig ~= "  email = " ~ (user.emailInfo.workEmail != "" ? user.emailInfo.workEmail : user.emailInfo.personalEmail) ~ "\n";
    gitConfig ~= "  name = " ~ user.userInfo.description ~ "\n";
    gitConfig ~= "[fetch]\n";
    gitConfig ~= "  prune = true\n";
    gitConfig ~= "[rebase]\n";
    gitConfig ~= "  updateRefs = true\n";
    gitConfig ~= "[pull]\n";
    gitConfig ~= "  ff = true\n";
    gitConfig ~= "  rebase = false\n";
    gitConfig ~= "[merge]\n";
    gitConfig ~= "  ff = only\n";
    gitConfig ~= "[core]\n";
    gitConfig ~= "  editor = nvim\n";
    gitConfig ~= "[include]\n";
    gitConfig ~= "  path = git/aliases.gitconfig\n";
    gitConfig ~= "  path = git/delta.gitconfig\n";
    gitConfig ~= "[difftool \"diffpdf\"]\n";
    gitConfig ~= "  cmd = diffpdf \\\"$LOCAL\\\" \\\"$REMOTE\\\"\n";
    gitConfig ~= "[difftool \"nvimdiff\"]\n";
    gitConfig ~= "  cmd = nvim -d \\\"$LOCAL\\\" \\\"$REMOTE\\\"\n";
    gitConfig ~= "[diff]\n";
    gitConfig ~= "  colorMoved = dimmed-zebra\n";
    return gitConfig;

}


void checkifNixosMachineConfigRepo()
{
    auto repoUrl = execute(["git", "config", "--get", "remote.origin.url"], false);
    if (repoUrl.indexOf("metacraft-labs/nixos-machine-config") == -1 &&
        repoUrl.indexOf("metacraft-labs/infra") == -1)
    {
        assert(0, "This is not the repo metacraft-labs/nixos-machine-config or metacraft-labs/infra");
    }
}

string[] getGroups()
{
    try {
        // Try to get groups from the users module using nix eval
        auto groupsJson = nix.eval!JSONValue("", [
            "--impure",
            "--expr",
            "(let lib = (import <nixpkgs> {}).lib; utils = import ./lib { usersDir = ./users; rootDir = ./.; machinesDir = ./machines; }; in lib.attrNames (utils.allAssignedGroups {}))"
        ]);
        return groupsJson.array.map!(a => a.str).array.sort.array;
    } catch (Exception e) {
        // Fallback to the old method if nix eval fails
        string[] groups = dirEntries("users", SpanMode.shallow).map!(a => a.name ~ "/user-info.nix").array.map!((a) {
            if (!std.file.exists(a))
            {
                return JSONValue(["metacraft"]).array;
            }
            auto userInfoFile = nix.eval!JSONValue(a, ["--file"]);
            if ("userInfo" !in userInfoFile || userInfoFile["userInfo"].isNull)
            {
                return JSONValue(["metacraft"]).array;
            }
            if ("extraGroups" !in userInfoFile["userInfo"] || userInfoFile["userInfo"]["extraGroups"].isNull)
            {
                return JSONValue(["metacraft"]).array;
            }
            return userInfoFile["userInfo"]["extraGroups"].array;
        }).array
            .joiner
            .array
            .map!(a => a.str)
            .array
            .sort
            .array
            .uniq
            .array;
        return groups;
    }
}

User createUser(CreateMachineArgs args) {

        auto createUser = args.createUser || prompt!bool("Create new user");
        if (!createUser)
        {
            string[] existingUsers = getExistingUsers();
            string userName = args.userName != "" ? args.userName : prompt!string("Select an existing username", existingUsers);
            return getUser(userName);
        }
        else
        {
            User user;
            user.userName = args.userName != "" ? args.userName : prompt!string("Enter the new username");
            user.userInfo.description = args.description != "" ? args.description : prompt!string("Enter the user's description/full name");
            user.userInfo.extraGroups = (args.extraGroups != "" ? args.extraGroups : prompt!string("Enter the user's extra groups (comma delimited)", getGroups())).split(",").map!(strip).array;
            createUserDir(user);
            return user;
        }
}

string calculateStateVersion() {
    import std.datetime : Clock;
    auto now = Clock.currTime();
    int year = now.year % 100; // Get last 2 digits
    int month = now.month;

    // NixOS releases in May (05) and November (11)
    // If before May, use previous year's November release
    // If before November, use current year's May release
    // Otherwise use current year's November release
    if (month < 5) {
        return (year == 0 ? 99 : year - 1).to!string ~ ".11";
    } else if (month < 11) {
        return year.to!string ~ ".05";
    } else {
        return year.to!string ~ ".11";
    }
}

string detectPlatform(Info info) {
    // Map D's architecture to Nix platform strings
    string arch = info.hardwareInfo.processorInfo.architectureInfo.architecture;
    string kernel = info.softwareInfo.operatingSystemInfo.kernel.toLower;

    if (arch.indexOf("x86_64") != -1 || arch.indexOf("x86-64") != -1) {
        if (kernel.indexOf("darwin") != -1) return "x86_64-darwin";
        return "x86_64-linux";
    } else if (arch.indexOf("aarch64") != -1 || arch.indexOf("arm64") != -1) {
        if (kernel.indexOf("darwin") != -1) return "aarch64-darwin";
        return "aarch64-linux";
    } else if (arch.indexOf("i686") != -1 || arch.indexOf("i386") != -1) {
        return "i686-linux";
    }

    // Default to x86_64-linux if unknown
    return "x86_64-linux";
}

string[] getValidUsers() {
    return getExistingUsers();
}

string detectElevationCommand(string sshPath) {
    // Try to detect if sudo or doas is available on the remote machine
    // First try sudo
    try {
        auto sudoCheck = execute(["ssh", sshPath, "command -v sudo"], false, false);
        if (sudoCheck.strip != "") {
            return "sudo";
        }
    } catch (Exception e) {
        // sudo not found, continue to check doas
    }

    // Try doas
    try {
        auto doasCheck = execute(["ssh", sshPath, "command -v doas"], false, false);
        if (doasCheck.strip != "") {
            return "doas";
        }
    } catch (Exception e) {
        // doas not found
    }

    // Default to sudo if neither is explicitly found
    // This maintains backward compatibility
    return "sudo";
}

struct MetaConfiguration
{
    struct MCL {
        struct HostInfo {
            string type;
            string sshKey;
        }
        HostInfo host_info;

        struct Users {
            string mainUser;
            string[] includedUsers;
            string[] includedGroups;
            bool enableHomeManager;
        }
        Users users;

        struct Secrets {
            string[] extraKeysFromGroups;
        }
        Secrets secrets;
    }
    MCL mcl;

    struct Nixpkgs {
        string hostPlatform;
    }
    Nixpkgs nixpkgs;

    struct Networking {
        string hostId;
    }
    Networking networking;

    struct System {
        string stateVersion;
    }
    System system;
}

struct MachineConfiguration
{
    struct Networking {
        string hostId;
    }
    Networking networking;
    struct MachineUserInfo {
        struct MCL {
            string[] includedUsers;
        }
        MCL mcl;
        struct UserData {
            string[] extraGroups;
        }
        UserData[string] users;
    }
    struct MCL {
        struct HostInfo {
            string sshKey;
        }
        HostInfo host_info;
    }
    MCL mcl;
    MachineUserInfo users;
}

void createMachine(CreateMachineArgs args, MachineType machineType, string machineName, User user) {
    auto infoJSON = execute(["ssh", args.sshPath, `nix --experimental-features "nix-command flakes" --refresh --accept-flake-config run /home/monyarm/code/repos/nixos-modules#mcl host-info`],false, false);
    auto infoJSONParsed = infoJSON.parseJSON;
    Info info = infoJSONParsed.fromJSON!Info;

    mkdirRecurse("machines/" ~ machineType.to!string ~ "/" ~ machineName);

    // Generate meta.nix
    MetaConfiguration metaConfiguration;

    // Determine host type
    if (args.hostType != "") {
        metaConfiguration.mcl.host_info.type = args.hostType;
    } else if (machineType == MachineType.server) {
        metaConfiguration.mcl.host_info.type = "server";
    } else {
        metaConfiguration.mcl.host_info.type = prompt!string("Enter host type (notebook/desktop/server)", ["notebook", "desktop", "server"]);
    }

    // SSH key - required for servers, optional for desktops/notebooks
    if (machineType == MachineType.server || metaConfiguration.mcl.host_info.type == "server") {
        metaConfiguration.mcl.host_info.sshKey = info.softwareInfo.opensshInfo.publicKey;
    } else if (args.hostType == "desktop" || args.hostType == "notebook") {
        // Optional for desktops/notebooks
        metaConfiguration.mcl.host_info.sshKey = "";
    }

    // Users configuration
    metaConfiguration.mcl.users.mainUser = args.mainUser != "" ? args.mainUser : user.userName;
    metaConfiguration.mcl.users.includedUsers = args.includedUsers != "" ? args.includedUsers.split(",").map!(strip).array : [];
    metaConfiguration.mcl.users.includedGroups = args.includedGroups != "" ? args.includedGroups.split(",").map!(strip).array : [];
    metaConfiguration.mcl.users.enableHomeManager = args.enableHomeManager || prompt!bool("Enable home-manager?");

    // Secrets configuration
    metaConfiguration.mcl.secrets.extraKeysFromGroups = args.extraKeysFromGroups != "" ? args.extraKeysFromGroups.split(",").map!(strip).array : [];

    // Platform and versions
    metaConfiguration.nixpkgs.hostPlatform = detectPlatform(info);
    metaConfiguration.networking.hostId = executeShell("tr -dc 0-9a-f < /dev/urandom | head -c 8").output.strip;
    metaConfiguration.system.stateVersion = calculateStateVersion();

    string metaNix = metaConfiguration.toNix(["config", "dots"]).replace("host_info", "host-info");
    std.file.write("machines/" ~ machineType.to!string ~ "/" ~ machineName ~ "/" ~ "meta.nix", metaNix);

    // Generate simpler configuration.nix (most moved to meta.nix)
    MachineConfiguration machineConfiguration;
    machineConfiguration.users.users[user.userName] = MachineConfiguration.MachineUserInfo.UserData([user.userName] ~ "wheel");
    machineConfiguration.users.mcl.includedUsers = [user.userName];
    machineConfiguration.networking.hostId = metaConfiguration.networking.hostId;
    machineConfiguration.mcl.host_info.sshKey = metaConfiguration.mcl.host_info.sshKey;
    string machineNix = machineConfiguration.toNix(["config", "dots"]).replace("host_info", "host-info");
    std.file.write("machines/" ~ machineType.to!string ~ "/" ~ machineName ~ "/" ~ "configuration.nix", machineNix);
    // writeln(info.toJSON(true).toPrettyString());

    HardwareConfiguration hardwareConfiguration;
    hardwareConfiguration.hardware.cpu["intel"] = HardwareConfiguration.Hardware.Cpu();

    switch (info.hardwareInfo.processorInfo.vendor) {
        case "GenuineIntel":
            hardwareConfiguration.hardware.cpu["intel"] = HardwareConfiguration.Hardware.Cpu();
            break;
        case "AuthenticAMD":
            hardwareConfiguration.hardware.cpu["amd"] = HardwareConfiguration.Hardware.Cpu();
            break;
        default:
            assert(0, "Unknown processor vendor " ~ info.hardwareInfo.processorInfo.vendor);
    }

    info.hardwareInfo.processorInfo.architectureInfo.flags.split(", ").each!((a) {
        if (a.strip == "vmx")
        {
            hardwareConfiguration.boot.kernelModules ~= "kvm-intel";
        }
        if (a.strip == "svm")
        {
            hardwareConfiguration.boot.kernelModules ~= "kvm-amd";
        }
    });
    hardwareConfiguration.boot.kernelModules ~= info.softwareInfo.machineConfigInfo.kernelModules;
    hardwareConfiguration.boot.initrd.kernelModules ~= info.softwareInfo.machineConfigInfo.kernelModules;
    hardwareConfiguration.boot.initrd.availableKernelModules ~= info.softwareInfo.machineConfigInfo.availableKernelModules;
    hardwareConfiguration.boot.extraModulePackages ~= info.softwareInfo.machineConfigInfo.extraModulePackages.map!(Literal).array;
    hardwareConfiguration._literalAttrs ~= info.softwareInfo.machineConfigInfo.literalAttrs.map!(Literal).array;
    hardwareConfiguration.imports ~= info.softwareInfo.machineConfigInfo.imports.map!(Literal).array;
    hardwareConfiguration.services.xserver.videoDrivers ~= info.softwareInfo.machineConfigInfo.videoDrivers;

    // Misc Kernel Modules
    hardwareConfiguration.boot.initrd.availableKernelModules ~= ["nvme", "xhci_pci", "usbhid", "usb_storage", "sd_mod"];

    // Disks - new structure
    hardwareConfiguration.disko.mcl.enable = true;

    // Parse partitioning preset
    if (args.partitioningPreset != "") {
        hardwareConfiguration.disko.mcl.partitioningPreset = args.partitioningPreset.replace("-", "_").to!PartitioningPreset;
    } else {
        hardwareConfiguration.disko.mcl.partitioningPreset = PartitioningPreset.zfs;
    }

    // Parse zpool mode
    if (args.zpoolMode != "") {
        hardwareConfiguration.disko.mcl.zpool.mode = args.zpoolMode.to!ZpoolMode;
    } else {
        hardwareConfiguration.disko.mcl.zpool.mode = ZpoolMode.stripe;
    }

    hardwareConfiguration.disko.mcl.espSize = args.espSize != "" ? args.espSize : "4G";

    // Calculate swap size
    string swapSize = args.swapSize != "" ? args.swapSize : (info.hardwareInfo.memoryInfo.totalGB.to!double*1.5).to!int.to!string ~ "G";
    hardwareConfiguration.disko.mcl.swap.size = swapSize;

    // Get disks
    auto nvmeDevices = info.hardwareInfo.storageInfo.devices.filter!(a => a.dev.indexOf("nvme") != -1 || a.model.indexOf("SSD") != -1).array.map!(a => a.model.replace(" ", "_") ~ "_" ~ a.serial).array;
    string[] disks = (nvmeDevices.length == 1 ? nvmeDevices[0] : (args.disks != "" ? args.disks : prompt!string("Enter the disks to use (comma delimited)", nvmeDevices))).split(",").map!(strip).array.map!(a => "/dev/disk/by-id/nvme-" ~ a).array;
    hardwareConfiguration.disko.mcl.disks = disks;

    hardwareConfiguration = hardwareConfiguration.uniqArrays;

    string hardwareNix = hardwareConfiguration.toNix(["config", "lib", "pkgs", "modulesPath", "dirs", "dots"])
        .replace("SYSTEMDBOOT", "systemd-boot")
        .replace("mcl.host-info.sshKey", "# mcl.host-info.sshKey");
    std.file.write("machines/" ~ machineType.to!string ~ "/" ~ machineName ~ "/" ~ "hw-config.nix", hardwareNix);
    execute(["alejandra", "machines/" ~ machineType.to!string ~ "/" ~ machineName ~ "/" ~ "meta.nix"], false);
    execute(["alejandra", "machines/" ~ machineType.to!string ~ "/" ~ machineName ~ "/" ~ "configuration.nix"], false);
    execute(["alejandra", "machines/" ~ machineType.to!string ~ "/" ~ machineName ~ "/" ~ "hw-config.nix"], false);
}

struct HardwareConfiguration {
    Literal[] _literalAttrs;
    Literal[] imports =  [];
    struct MCLDisko {
        bool enable = true;
        PartitioningPreset partitioningPreset = PartitioningPreset.zfs;
        struct Zpool {
            ZpoolMode mode = ZpoolMode.stripe;
        }
        Zpool zpool;
        string espSize = "4G";
        struct Swap {
            string size;
        }
        Swap swap;
        string[] disks;
    }
    struct Disko {
        MCLDisko mcl;
    }
    Disko disko;
    struct Boot {
        struct Initrd {
            string[] kernelModules;
            string[] availableKernelModules;
        }
        Initrd initrd;
        string[] kernelModules;
        Literal[] extraModulePackages;
        struct Loader {
            struct SystemdBoot {
                bool enable = true;
            }
            SystemdBoot SYSTEMDBOOT;
            struct Grub {
                bool enable = false;
                bool efiSupport = true;
                Literal devices = Literal("builtins.attrNames config.disko.devices.disk");
                bool copyKernels = true;
            }
            Grub grub;
            struct EFI {
                Literal canTouchEfiVariables = mkDefault(true);
            }
            EFI efi;
        }
        Loader loader;
        string[] blacklistedKernelModules;
    }
    Boot boot;
    struct Networking {
        // struct UseDHCP {
        //     Literal useDHCP = mkDefault(true);
        // }
        // UseDHCP[string] interfaces;
        Literal useDHCP = mkDefault(true);
    }
    Networking networking;
    struct PowerManagement {
        Literal cpuFreqGovernor = mkDefault("performance");
    }
    PowerManagement powerManagement;
    struct Hardware {
        struct Cpu {
            bool updateMicrocode = true;
        }
        Cpu[string] cpu;
        bool enableAllFirmware = true;
        Literal enableRedistributableFirmware = mkDefault(true);
    }
    Hardware hardware;
    struct Services {
        struct Xserver {
            bool enable = true;
            string[] videoDrivers;
        }
        Xserver xserver;
    }
    Services services;
}

int createMachineConfiguration(CreateMachineArgs args)
{
    checkifNixosMachineConfigRepo();
    auto machineType = cast(int)args.machineType != 0 ? args.machineType : prompt!MachineType("Machine type");
    auto machineName = args.machineName != "" ? args.machineName : prompt!string("Enter the name of the machine");
    User user;
    user = createUser(args);
    args.createMachine(machineType, machineName, user);
    return 0;
}


export int machine(MachineArgs args)
{
    return args.cmd.matchCmd!(
        (CreateMachineArgs a) => createMachineConfiguration(a),
        (UnknownCommandArgs a) => unknown_command(a)
    );
}

@(Command("create").Description("Create a new machine"))
struct CreateMachineArgs
{
    @(PositionalArgument(0).Placeholder("ssh").Description("SSH path to the machine"))
    string sshPath;
    @(NamedArgument(["create-user"]).Placeholder("true/false").Description("Create a new user"))
    bool createUser;
    @(NamedArgument(["user-name"]).Placeholder("username").Description("Username"))
    string userName;
    @(NamedArgument(["machine-name"]).Placeholder("machine-name").Description("Name of the machine"))
    string machineName;
    @(NamedArgument(["description"]).Placeholder("description").Description("Description of the user"))
    string description;
    @(NamedArgument(["extra-groups"]).Placeholder("group1,group2").Description("Extra groups for the user"))
    string extraGroups;
    @(NamedArgument(["machine-type"]).Placeholder("desktop/server/container").Description("Type of machine"))
    MachineType machineType = cast(MachineType)0;
    @(NamedArgument(["disks"]).Placeholder("CT2000P3PSSD8_2402E88C1519,...").Description("Disks to use"))
    string disks;

    // New meta.nix arguments
    @(NamedArgument(["host-type"]).Placeholder("notebook/desktop/server").Description("Host type (notebook, desktop, or server)"))
    string hostType;
    @(NamedArgument(["main-user"]).Placeholder("username").Description("Main user for the machine"))
    string mainUser;
    @(NamedArgument(["included-users"]).Placeholder("user1,user2").Description("Additional users to include"))
    string includedUsers;
    @(NamedArgument(["included-groups"]).Placeholder("group1,group2").Description("Groups to include"))
    string includedGroups;
    @(NamedArgument(["enable-home-manager"]).Description("Enable home-manager"))
    bool enableHomeManager;
    @(NamedArgument(["extra-keys-from-groups"]).Placeholder("group1,group2").Description("Extra SSH keys from groups"))
    string extraKeysFromGroups;

    // New email/user info arguments
    @(NamedArgument(["description-bg"]).Placeholder("description").Description("Bulgarian description"))
    string descriptionBG;
    @(NamedArgument(["email-aliases"]).Placeholder("email1,email2").Description("Email aliases"))
    string emailAliases;
    @(NamedArgument(["github-username"]).Placeholder("username").Description("GitHub username"))
    string githubUsername;
    @(NamedArgument(["discord-username"]).Placeholder("username").Description("Discord username"))
    string discordUsername;

    // New disko arguments
    @(NamedArgument(["partitioning-preset"]).Placeholder("zfs/zfs-legacy/ext4").Description("Partitioning preset"))
    string partitioningPreset;
    @(NamedArgument(["zpool-mode"]).Placeholder("mirror/raidz1/raidz2/raidz3/stripe").Description("ZFS pool mode"))
    string zpoolMode;
    @(NamedArgument(["esp-size"]).Placeholder("4G").Description("ESP partition size"))
    string espSize;
    @(NamedArgument(["swap-size"]).Placeholder("96G").Description("Swap size (overrides automatic calculation)"))
    string swapSize;
}

@(Command(" ").Description(" "))
struct UnknownCommandArgs { }

int unknown_command(UnknownCommandArgs unused)
{
    stderr.writeln("Unknown machine command. Use --help for a list of available commands.");
    return 1;
}

@(Command("machine").Description("Manage machines"))
struct MachineArgs
{
    SubCommand!(CreateMachineArgs,Default!UnknownCommandArgs) cmd;
}
