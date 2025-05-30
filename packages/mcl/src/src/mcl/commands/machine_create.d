module mcl.commands.machine_create;

import std;
import mcl.utils.log : prompt;
import mcl.utils.process : execute;
import mcl.utils.nix : nix, toNix, Literal, mkDefault;
import mcl.utils.json : toJSON, fromJSON;
import mcl.utils.env : optional, parseEnv;
import mcl.utils.array : uniqArrays;
import mcl.commands.host_info: Info;

enum MachineType
{
    desktop = 1,
    server = 2,
    container = 3
}

enum Group
{
    metacraft,
    devops,
    codetracer,
    dendreth,
    blocksense
}

struct User {
    string userName;
    UserInfo userInfo;
    EmailInfo emailInfo;
}

struct UserInfo
{
    bool isNormalUser;
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
    user.userInfo.isNormalUser = userJson["userInfo"]["isNormalUser"].boolean;
    user.userInfo.description = userJson["userInfo"]["description"].str;
    user.userInfo.extraGroups = userJson["userInfo"]["extraGroups"].array.map!(a => a.str).array;
    user.userInfo.hashedPassword = userJson["userInfo"]["hashedPassword"].str;
    user.userInfo.sshKeys = userJson["userInfo"]["openssh"]["authorizedKeys"]["keys"].array.map!(a => a.str).array;
    user.emailInfo.personalEmail = ("personalEmail" in userJson["emailInfo"].object) ? userJson["emailInfo"]["personalEmail"].str : "";
    user.emailInfo.workEmail = ("workEmail" in userJson["emailInfo"].object) ? userJson["emailInfo"]["workEmail"].str : user.emailInfo.personalEmail;
    user.emailInfo.gitlabUsername = ("gitlabUsername" in userJson["emailInfo"].object) ? userJson["emailInfo"]["gitlabUsername"].str : "";
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
    if (execute(["git", "config", "--get", "remote.origin.url"], false)
        .indexOf("metacraft-labs/nixos-machine-config") == -1)
    {
        assert(0, "This is not the repo metacraft-labs/nixos-machine-config");
    }
}

string[] getGroups()
{
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

User createUser() {

        auto createUser = params.createUser || prompt!bool("Create new user");
        if (!createUser)
        {
            string[] existingUsers = getExistingUsers();
            string userName = params.userName != "" ? params.userName : prompt!string("Select an existing username", existingUsers);
            return getUser(userName);
        }
        else
        {
            User user;
            user.userName = params.userName != "" ? params.userName : prompt!string("Enter the new username");
            user.userInfo.description = params.description != "" ? params.description : prompt!string("Enter the user's description/full name");
            user.userInfo.isNormalUser = params.isNormalUser || prompt!bool("Is this a normal or root user");
            user.userInfo.extraGroups = (params.extraGroups != "" ? params.extraGroups : prompt!string("Enter the user's extra groups (comma delimited)", getGroups())).split(",").map!(strip).array;
            createUserDir(user);
            return user;
        }
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

void createMachine(MachineType machineType, string machineName, User user) {
    auto infoJSON = execute(["ssh", params.sshPath, "sudo nix --experimental-features \\'nix-command flakes\\' --refresh --accept-flake-config run github:metacraft-labs/nixos-modules/feat/machine_create#mcl host_info"],false, false);
    auto infoJSONParsed = infoJSON.parseJSON;
    Info info = infoJSONParsed.fromJSON!Info;

    MachineConfiguration machineConfiguration;
    machineConfiguration.users.users[user.userName] = MachineConfiguration.MachineUserInfo.UserData([user.userName] ~ "wheel");
    machineConfiguration.users.mcl.includedUsers = [user.userName];
    machineConfiguration.networking.hostId = executeShell("tr -dc 0-9a-f < /dev/urandom | head -c 8").output;
    machineConfiguration.mcl.host_info.sshKey = info.softwareInfo.opensshInfo.publicKey;
    string machineNix = machineConfiguration.toNix(["config", "dots"]).replace("host_info", "host-info");
    mkdirRecurse("machines/" ~ machineType.to!string ~ "/" ~ machineName);
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

    // Disks
    hardwareConfiguration.disko.DISKO.makeZfsPartitions.swapSizeGB = (info.hardwareInfo.memoryInfo.totalGB.to!double*1.5).to!int;
    auto nvmeDevices = info.hardwareInfo.storageInfo.devices.filter!(a => a.dev.indexOf("nvme") != -1 || a.model.indexOf("SSD") != -1).array.map!(a => a.model.replace(" ", "_") ~ "_" ~ a.serial).array;
    string[] disks = (nvmeDevices.length == 1 ? nvmeDevices[0] : (params.disks != "" ? params.disks : prompt!string("Enter the disks to use (comma delimited)", nvmeDevices))).split(",").map!(strip).array.map!(a => "/dev/disk/by-id/nvme-" ~ a).array;
    hardwareConfiguration.disko.DISKO.makeZfsPartitions.disks = disks;

    hardwareConfiguration = hardwareConfiguration.uniqArrays;


    string hardwareNix = hardwareConfiguration.toNix(["config", "lib", "pkgs", "modulesPath", "dirs", "dots"])
        .replace("DISKO", "(import \"${dirs.lib}/disko.nix\")")
        .replace ("makeZfsPartitions = ", "makeZfsPartitions ")
        .replace("SYSTEMDBOOT", "systemd-boot")
        .replace("mcl.host-info.sshKey", "# mcl.host-info.sshKey");
    std.file.write("machines/" ~ machineType.to!string ~ "/" ~ machineName ~ "/" ~ "hw-config.nix", hardwareNix);
    execute(["alejandra", "machines/" ~ machineType.to!string ~ "/" ~ machineName ~ "/" ~ "configuration.nix"], false);
    execute(["alejandra", "machines/" ~ machineType.to!string ~ "/" ~ machineName ~ "/" ~ "hw-config..nix"], false);
}

struct HardwareConfiguration {
    Literal[] _literalAttrs;
    Literal[] imports =  [];
    struct Disko {
        struct INNER_DISKO {
            struct MakeZfsPartition {
                string[] disks;
                int swapSizeGB;
                int espSizeGB = 4;
                Literal _literalConfig = "inherit config;";
            }
            MakeZfsPartition makeZfsPartitions;
        }
        INNER_DISKO DISKO;
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
                Literal canTouchEfiVariables = mkDefault(true);;
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

void createMachineConfiguration()
{
    checkifNixosMachineConfigRepo();
    auto machineType = cast(int)params.machineType != 0 ? params.machineType : prompt!MachineType("Machine type");
    auto machineName = params.machineName != "" ? params.machineName : prompt!string("Enter the name of the machine");
    User user;
    user = createUser();
    machineType.createMachine( machineName, user);
}

Params params;

export void machine_create(string[] args)
{
    params = parseEnv!Params;
    createMachineConfiguration();
}
struct Params
{
    string sshPath;
    @optional() bool createUser;
    @optional() string userName;
    @optional() string machineName;
    @optional() string description;
    @optional() bool isNormalUser;
    @optional() string extraGroups;
    @optional() MachineType machineType = cast(MachineType)0;
    @optional() string disks;

    void setup()
    {
    }
}
