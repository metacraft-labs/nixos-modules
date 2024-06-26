module mcl.commands.host_info;

import cpuid.x86_any;
import cpuid.unified;
import core.cpuid;
import std.system;

import std.stdio : writeln;
import std.conv : to;
import std.string : strip, indexOf, isNumeric;
import std.array : split, join, array, replace;
import std.algorithm : map, filter, startsWith, joiner, any, sum, find;
import std.file : exists, write, readText, readLink, dirEntries, SpanMode;
import std.path : baseName;
import std.json;
import std.process : ProcessPipes, environment;
import core.stdc.string: strlen;

import mcl.utils.env : parseEnv, optional;
import mcl.utils.json : toJSON;
import mcl.utils.process : execute, isRoot;
import mcl.utils.number : humanReadableSize;
import mcl.utils.array : uniqIfSame;
import mcl.utils.nix : Literal;
import mcl.utils.coda;

// enum InfoFormat
// {
//     JSON,
//     CSV,
//     TSV
// }

struct Params
{
    // @optional()
    // InfoFormat format = InfoFormat.JSON;
    @optional() string codaApiToken;
    void setup()
    {
    }
}
Params params;

string[string] cpuinfo;

string[string] meminfo;

string[string] getProcInfo(string fileOrData, bool file = true)
{
    string[string] r;
    foreach (line; file ? fileOrData.readText().split(
            "\n").map!(strip).array : fileOrData.split("\n").map!(strip).array)
    {
        if (line.indexOf(":") == -1 || line.strip == "edid-decode (hex):")
        {
            continue;
        }
        auto parts = line.split(":");
        if (parts.length >= 2 && parts[0].strip != "")
        {
            r[parts[0].strip] = parts[1].strip;
        }
    }
    return r;
}

export void host_info()
{
    params = parseEnv!Params;

    Info info = getInfo();

    writeln(info.toJSON(true).toPrettyString(JSONOptions.doNotEscapeSlashes));

}

Info getInfo()
{

    cpuinfo = getProcInfo("/proc/cpuinfo");
    meminfo = getProcInfo("/proc/meminfo");

    Info info;
    info.softwareInfo.hostid = execute("hostid", false);
    info.softwareInfo.hostname = execute("cat /etc/hostname", false);
    info.softwareInfo.operatingSystemInfo = getOperatingSystemInfo();
    info.softwareInfo.opensshInfo = getOpenSSHInfo();
    info.softwareInfo.machineConfigInfo = getMachineConfigInfo();

    info.hardwareInfo.processorInfo = getProcessorInfo();
    info.hardwareInfo.motherboardInfo = getMotherboardInfo();
    info.hardwareInfo.memoryInfo = getMemoryInfo();
    info.hardwareInfo.storageInfo = getStorageInfo();
    info.hardwareInfo.displayInfo = getDisplayInfo();
    info.hardwareInfo.graphicsProcessorInfo = getGraphicsProcessorInfo();

    if (params.codaApiToken) {
        auto docId = "0rz18jyJ1M";
        auto hostTableId = "grid-b3MAjem325";
        auto cpuTableId = "grid-mCI3x3nEIE";
        auto memoryTableId = "grid-o7o2PeB4rz";
        auto motherboardTableId = "grid-270PlzmA8K";
        auto gpuTableId = "grid-ho6EPztvni";
        auto storageTableId = "grid-JvXFbttMNz";
        auto osTableId = "grid-ora7n98-ls";
        auto coda = CodaApiClient(params.codaApiToken);

        auto hostValues = RowValues([
            CodaCell("Host Name", info.softwareInfo.hostname),
            CodaCell("Host ID", info.softwareInfo.hostid),
            CodaCell("OpenSSH Public Key", info.softwareInfo.opensshInfo.publicKey),
            CodaCell("JSON", info.toJSON(true).toPrettyString(JSONOptions.doNotEscapeSlashes))
        ]);

        coda.updateOrInsertRow(docId, hostTableId, hostValues);

        auto cpuValues = RowValues([
            CodaCell("Host Name", info.softwareInfo.hostname),
            CodaCell("Vendor", info.hardwareInfo.processorInfo.vendor),
            CodaCell("Model", info.hardwareInfo.processorInfo.model),
            CodaCell("Architecture", info.hardwareInfo.processorInfo.architectureInfo.architecture),
            CodaCell("Flags", info.hardwareInfo.processorInfo.architectureInfo.flags),
        ]);
        coda.updateOrInsertRow(docId, cpuTableId, cpuValues);

        auto memoryValues = RowValues([
            CodaCell("Host Name", info.softwareInfo.hostname),
            CodaCell("Vendor", info.hardwareInfo.memoryInfo.vendor),
            CodaCell("Part Number", info.hardwareInfo.memoryInfo.partNumber),
            CodaCell("Serial", info.hardwareInfo.memoryInfo.serial),
            CodaCell("Generation", info.hardwareInfo.memoryInfo.type),
            CodaCell("Slots", info.hardwareInfo.memoryInfo.slots == 0 ? "Soldered" : info.hardwareInfo.memoryInfo.count.to!string ~ "/" ~ info.hardwareInfo.memoryInfo.slots.to!string),
            CodaCell("Total", info.hardwareInfo.memoryInfo.total),
            CodaCell("Speed", info.hardwareInfo.memoryInfo.speed),
        ]);
        coda.updateOrInsertRow(docId, memoryTableId, memoryValues);

        auto motherboardValues = RowValues([
            CodaCell("Host Name", info.softwareInfo.hostname),
            CodaCell("Vendor", info.hardwareInfo.motherboardInfo.vendor),
            CodaCell("Model", info.hardwareInfo.motherboardInfo.model),
            CodaCell("Revision", info.hardwareInfo.motherboardInfo.version_),
            CodaCell("Serial", info.hardwareInfo.motherboardInfo.serial),
            CodaCell("BIOS Vendor", info.hardwareInfo.motherboardInfo.biosInfo.vendor),
            CodaCell("BIOS Version", info.hardwareInfo.motherboardInfo.biosInfo.version_),
            CodaCell("BIOS Release", info.hardwareInfo.motherboardInfo.biosInfo.release),
            CodaCell("BIOS Date", info.hardwareInfo.motherboardInfo.biosInfo.date)
        ]);
        coda.updateOrInsertRow(docId, motherboardTableId, motherboardValues);

        auto gpuValues = RowValues([
            CodaCell("Host Name", info.softwareInfo.hostname),
            CodaCell("Vendor", info.hardwareInfo.graphicsProcessorInfo.vendor),
            CodaCell("Model", info.hardwareInfo.graphicsProcessorInfo.model),
            CodaCell("VRam", info.hardwareInfo.graphicsProcessorInfo.vram)
        ]);
        coda.updateOrInsertRow(docId, gpuTableId, gpuValues);

        auto osValues = RowValues([
            CodaCell("Host Name", info.softwareInfo.hostname),
            CodaCell("Distribution", info.softwareInfo.operatingSystemInfo.distribution),
            CodaCell("Distribution Version", info.softwareInfo.operatingSystemInfo.distributionVersion),
            CodaCell("Kernel", info.softwareInfo.operatingSystemInfo.kernel),
            CodaCell("Kernel Version", info.softwareInfo.operatingSystemInfo.kernelVersion)
        ]);
        coda.updateOrInsertRow(docId, osTableId, osValues);

        auto storageValues = RowValues([
            CodaCell("Host Name", info.softwareInfo.hostname),
            CodaCell("Count", info.hardwareInfo.storageInfo.devices.length.to!string),
            CodaCell("Total", info.hardwareInfo.storageInfo.total),
            CodaCell("JSON", info.hardwareInfo.storageInfo.toJSON(true).toPrettyString(JSONOptions.doNotEscapeSlashes))
        ]);
        coda.updateOrInsertRow(docId, storageTableId, storageValues);
    }

    return info;
}

struct Info
{
    SoftwareInfo softwareInfo;
    HardwareInfo hardwareInfo;
}

struct SoftwareInfo
{
    string hostname;
    string hostid;
    OperatingSystemInfo operatingSystemInfo;
    OpenSSHInfo opensshInfo;
    MachineConfigInfo machineConfigInfo;
}

struct HardwareInfo
{
    ProcessorInfo processorInfo;
    MotherboardInfo motherboardInfo;
    MemoryInfo memoryInfo;
    StorageInfo storageInfo;
    DisplayInfo displayInfo;
    GraphicsProcessorInfo graphicsProcessorInfo;
}

struct ArchitectureInfo
{
    string architecture;
    string opMode;
    string byteOrder;
    string addressSizes;
    string flags;
}

ArchitectureInfo getArchitectureInfo()
{
    ArchitectureInfo r;
    r.architecture = instructionSetArchitecture.to!string;
    r.byteOrder = endian.to!string;
    r.addressSizes = cpuinfo["address sizes"];
    r.opMode = getOpMode();
    r.flags = cpuinfo["flags"].split(" ").map!(a => a.strip).join(", ");

    return r;
}

string getOpMode()
{
    int[] opMode = [];
    switch (instructionSetArchitecture)
    {
    case ISA.avr:
        opMode = [8];
        break;
    case ISA.msp430:
        opMode = [16];
        break;
    case ISA.x86_64:
    case ISA.aarch64:
    case ISA.ppc64:
    case ISA.mips64:
    case ISA.nvptx64:
    case ISA.riscv64:
    case ISA.sparc64:
    case ISA.hppa64:
        opMode = [32, 64];
        break;
    case ISA.x86:
    case ISA.arm:
    case ISA.ppc:
    case ISA.mips32:
    case ISA.nvptx:
    case ISA.riscv32:
    case ISA.sparc:
    case ISA.s390:
    case ISA.hppa:
    case ISA.sh:
    case ISA.webAssembly:
        opMode = [32];
        break;
    case ISA.ia64:
    case ISA.alpha:
        opMode = [64];
        break;
    case ISA.systemZ:
        opMode = [24, 31, 32, 64];
        break;
    case ISA.epiphany:
    default:
        throw new Exception(
            "Unsupported architecture" ~ instructionSetArchitecture.to!string);
    }
    return opMode.map!(to!string).join("-bit, ") ~ "-bit";
}

struct ProcessorInfo
{
    ArchitectureInfo architectureInfo;
    string model;
    string vendor;
    size_t cpus;
    size_t[] cores;
    size_t[] threads;
    string voltage;
    size_t[] frequency;
    size_t[] maxFrequency;
}

ProcessorInfo getProcessorInfo()
{
    ProcessorInfo r;
    r.vendor = cpuid.x86_any.vendor;
    char[48] modelCharArr;
    cpuid.x86_any.brand(modelCharArr);
    r.model = modelCharArr.idup[0..(strlen(modelCharArr.ptr)-1)];
    r.cpus = cpuid.unified.cpus();
    r.cores = [r.cpus * cpuid.unified.cores()];
    r.threads = [cpuid.unified.threads()];
    r.architectureInfo = getArchitectureInfo();

    if (isRoot)
    {
        auto dmi = execute("dmidecode -t 4", false).split("\n");
        r.voltage = dmi.getFromDmi("Voltage:").map!(a => a.split(" ")[0]).array.uniqIfSame[0];
        r.frequency = dmi.getFromDmi("Current Speed:")
            .map!(a => a.split(" ")[0].to!size_t).array.uniqIfSame;
        r.maxFrequency = dmi.getFromDmi("Max Speed:")
            .map!(a => a.split(" ")[0].to!size_t).array.uniqIfSame;
        r.cpus = dmi.getFromDmi("Processor Information").length;
        r.cores = dmi.getFromDmi("Core Count").map!(a => a.to!size_t).array.uniqIfSame;
        r.threads = dmi.getFromDmi("Thread Count").map!(a => a.to!size_t).array.uniqIfSame;
    }

    return r;
}

struct MotherboardInfo
{
    string vendor;
    string model;
    string version_;
    string serial = "ROOT PERMISSIONS REQUIRED";
    BiosInfo biosInfo;
}

struct BiosInfo
{
    string date;
    string version_;
    string release;
    string vendor;
}

MotherboardInfo getMotherboardInfo()
{
    MotherboardInfo r;

    r.vendor = readText("/sys/devices/virtual/dmi/id/board_vendor").strip;
    r.model = readText("/sys/devices/virtual/dmi/id/board_name").strip;
    r.version_ = readText("/sys/devices/virtual/dmi/id/board_version").strip;
    if (isRoot)
    {
        r.serial = readText("/sys/devices/virtual/dmi/id/board_serial").strip;
    }

    r.biosInfo = getBiosInfo();

    return r;
}

BiosInfo getBiosInfo()
{
    BiosInfo r;
    r.date = readText("/sys/devices/virtual/dmi/id/bios_date").strip;
    r.version_ = readText("/sys/devices/virtual/dmi/id/bios_version").strip;
    r.release = readText("/sys/devices/virtual/dmi/id/bios_release").strip;
    r.vendor = readText("/sys/devices/virtual/dmi/id/bios_vendor").strip;

    return r;
}

struct OperatingSystemInfo
{
    string kernel;
    string kernelVersion;
    string distribution;
    string distributionVersion;
}

OperatingSystemInfo getOperatingSystemInfo()
{
    OperatingSystemInfo r;

    r.kernel = getKernel();
    r.kernelVersion = getKernelVersion();
    r.distribution = getDistribution();
    r.distributionVersion = getDistributionVersion();

    return r;
}

string getKernel()
{
    return execute("uname -s", false);
};

string getKernelVersion()
{
    return execute("uname -r", false);
}

string getDistribution()
{
    auto distribution = execute("uname -o", false);
    if (exists("/etc/os-release"))
    {
        foreach (line; execute([
                "awk", "-F", "=", "'/^NAME=/ {print $2}'", "/etc/os-release"
            ], false).split("\n"))
        {
            distribution = line;
        }
    }
    else if (distribution == "Darwin")
    {
        distribution = execute("sw_vers", false);
    }
    else if (exists("/etc/lsb-release"))
    {
        distribution = execute("lsb_release -i", false);
    }
    return distribution;
}

string getDistributionVersion()
{
    auto distributionVersion = execute("uname -r", false);
    if (exists("/etc/os-release"))
    {
        foreach (line; execute([
                "awk", "-F", "=", "'/^VERSION=/ {print $2}'", "/etc/os-release"
            ], false).split("\n"))
        {
            distributionVersion = line.strip("\"");
        }
    }
    else if (execute("uname -o") == "Darwin")
    {
        distributionVersion = execute("sw_vers -productVersion", false) ~ " ( " ~ execute(
            "sw_vers -buildVersion", false) ~ " )";
    }
    else if (exists("/etc/lsb-release"))
    {
        distributionVersion = execute("lsb_release -r", false);
    }
    return distributionVersion;
}

struct MemoryInfo
{
    string total;
    int totalGB;
    size_t count;
    size_t slots;
    string type = "ROOT PERMISSIONS REQUIRED";
    bool[] ecc;
    string speed = "ROOT PERMISSIONS REQUIRED";
    string vendor = "ROOT PERMISSIONS REQUIRED";
    string partNumber = "ROOT PERMISSIONS REQUIRED";
    string serial = "ROOT PERMISSIONS REQUIRED";
}

string[] getFromDmi(string[] dmi, string key)
{
    return dmi.filter!(a => a.strip.startsWith(key))
        .map!(x => x.indexOf(":") != -1 ? x.split(":")[1].strip : x)
        .filter!(a => a != "Unknown" && a != "No Module Installed" && a != "Not Provided" && a != "None")
        .array;
}

MemoryInfo getMemoryInfo()
{
    MemoryInfo r;
    auto memTotal = (meminfo["MemTotal"].split(" ")[0].to!size_t) * 1024;
    r.total = memTotal.humanReadableSize;
    r.totalGB = r.total.split(" ")[0].to!int;
    if (isRoot)
    {
        string[] dmi = execute("dmidecode -t memory", false).split("\n");
        r.type = dmi.getFromDmi("Type:").uniqIfSame.join("/");
        r.count = dmi.getFromDmi("Type:").length;
        r.slots = dmi.getFromDmi("Memory Device")
            .filter!(a => a.indexOf("DMI type 17") != -1).array.length;
        r.totalGB = dmi.getFromDmi("Size:").map!(a => a.split(" ")[0]).array.filter!(isNumeric).array.map!(to!int).array.sum();
        r.total =r.totalGB.to!string ~ " GB (" ~ dmi.getFromDmi("Size:").map!(a => a.split(" ")[0]).join("/") ~ ")";
        auto totalWidth = dmi.getFromDmi("Total Width");
        auto dataWidth = dmi.getFromDmi("Data Width");
        foreach (i, width; totalWidth)
        {
            r.ecc ~= dataWidth[i] != width;
        }
        r.speed = dmi.getFromDmi("Speed:").uniqIfSame.join("/");
        r.vendor = dmi.getFromDmi("Manufacturer:").uniqIfSame.join("/");
        r.partNumber = dmi.getFromDmi("Part Number:").uniqIfSame.join("/");
        r.serial = dmi.getFromDmi("Serial Number:").uniqIfSame.join("/");

    }

    return r;

}

struct Partition
{
    string dev;
    string size;
    string type;
    string mount;
    string fslabel;
    string partlabel;
    string id;
}

struct Device
{
    string dev;
    string uuid;
    string type;
    string size;
    string model;
    string serial;
    string vendor;
    string state;
    string partitionTableType;
    string partitionTableUUID;
    Partition[] partitions;

}

struct StorageInfo
{
    string total;
    Device[] devices;
}

StorageInfo getStorageInfo()
{
    StorageInfo r;
    auto lsblk = execute!JSONValue(
        "lsblk --nodeps -o KNAME,ID,TYPE,SIZE,MODEL,SERIAL,VENDOR,STATE,PTTYPE,PTUUID -J", false);
    real total = 0;
    foreach (JSONValue dev; lsblk["blockdevices"].array)
    {
        if (dev["id"].isNull)
        {
            continue;
        }
        Device d;
        d.dev = dev["kname"].isNull ? "" : dev["kname"].str;
        d.uuid = dev["id"].isNull ? "" : dev["id"].str;
        d.type = dev["type"].isNull ? "" : dev["type"].str;
        d.size = dev["size"].isNull ? "" : dev["size"].str;
        d.model = dev["model"].isNull ? "Unknown Model" : dev["model"].str;
        d.serial = dev["serial"].isNull ? "Missing Serial Number" : dev["serial"].str;
        d.vendor = dev["vendor"].isNull ? "Unknown Vendor" : dev["vendor"].str;
        d.state = dev["state"].isNull ? "" : dev["state"].str;
        d.partitionTableType = dev["pttype"].isNull ? "" : dev["pttype"].str;
        d.partitionTableUUID = dev["ptuuid"].isNull ? "" : dev["ptuuid"].str;

        switch (d.size[$ - 1])
        {
        case 'B':
            total += d.size[0 .. $ - 1].to!real;
            break;
        case 'K':
            total += d.size[0 .. $ - 1].to!real * 1024;
            break;
        case 'M':
            total += d.size[0 .. $ - 1].to!real * 1024 * 1024;
            break;
        case 'G':
            total += d.size[0 .. $ - 1].to!real * 1024 * 1024 * 1024;
            break;
        case 'T':
            total += d.size[0 .. $ - 1].to!real * 1024 * 1024 * 1024 * 1024;
            break;
        default:
            assert(0, "Unknown size unit" ~ d.size[$ - 1]);
        }

        if (isRoot)
        {
            auto partData = execute!JSONValue("lsblk -o KNAME,SIZE,PARTFLAGS,PARTLABEL,PARTN,PARTTYPE,PARTTYPENAME,PARTUUID,MOUNTPOINT,FSTYPE,LABEL -J /dev/" ~ d
                    .dev, false)["blockdevices"].array;
            foreach (JSONValue part; partData.array)
            {
                if (part["partuuid"].isNull)
                {
                    continue;
                }
                Partition p;
                p.dev = part["kname"].isNull ? "" : part["kname"].str;
                p.fslabel = part["label"].isNull ? "" : part["label"].str;
                p.partlabel = part["partlabel"].isNull ? "" : part["partlabel"].str;
                p.size = part["size"].isNull ? "" : part["size"].str;
                p.type = part["fstype"].isNull ? "" : part["fstype"].str;
                p.mount = part["mountpoint"].isNull ? "Not Mounted" : part["mountpoint"].str;
                p.id = part["partuuid"].isNull ? "" : part["partuuid"].str;
                d.partitions ~= p;
            }
        }

        r.devices ~= d;
    }
    r.total = total.humanReadableSize;

    return r;
}

struct Display
{
    string name;
    string vendor;
    string model;
    string serial;
    string resolution;
    string[] modes;
    string refreshRate;
    string size;
    bool connected;
    bool primary;
    string manufactureDate;
}

struct DisplayInfo
{
    Display[] displays;
    size_t count;
}

DisplayInfo getDisplayInfo()
{
    DisplayInfo r;
    if ("DISPLAY" !in environment)
        return r;
    try
    {
        auto xrandr = execute!JSONValue("jc xrandr --properties", false)["screens"].array;
        foreach (JSONValue screen; xrandr)
        {
            foreach (JSONValue device; screen["devices"].array)
            {
                Display d;

                d.name = device["device_name"].str;
                d.connected = device["is_connected"].boolean;
                d.primary = device["is_primary"].boolean;
                d.resolution = device["resolution_width"].integer.to!string ~ "x" ~ device["resolution_height"]
                    .integer.to!string;
                foreach (JSONValue mode; device["modes"].array)
                {
                    foreach (JSONValue freq; mode["frequencies"].array)
                    {
                        d.modes ~= mode["resolution_width"].integer.to!string ~ "x" ~ mode["resolution_height"].integer
                            .to!string ~ "@" ~ freq["frequency"].floating.to!string ~ "Hz";
                        if (freq["is_current"].boolean)
                        {
                            d.refreshRate = freq["frequency"].floating.to!string ~ "Hz";
                        }
                    }
                }
                if ("/sys/class/rm/card0-" ~ d.name.replace("HDMI-", "HDMI-A-") ~ "/edid".exists)
                {
                    auto edidTmp = execute("edid-decode /sys/class/drm/card0-" ~ d.name.replace("HDMI-", "HDMI-A-") ~ "/edid", false);
                    auto edidData = getProcInfo(edidTmp, false);
                    d.vendor = ("Manufacturer" in edidData) ? edidData["Manufacturer"] : "Unknown";
                    d.model = ("Model" in edidData) ? edidData["Model"] : "Unknown";
                    d.serial = ("Serial Number" in edidData) ? edidData["Serial Number"] : "Unknown";
                    d.manufactureDate = ("Made in" in edidData) ? edidData["Made in"] : "Unknown";
                    d.size = ("Maximum image size" in edidData) ? edidData["Maximum image size"] : "Unknown";
                }

                r.displays ~= d;
                r.count++;
            }
        }
    }
    catch (Exception e)
    {
        return r;
    }
    return r;
}

struct GraphicsProcessorInfo
{
    string vendor;
    string model;
    string coreProfile;
    string vram;
}

GraphicsProcessorInfo getGraphicsProcessorInfo()
{
    GraphicsProcessorInfo r;
    if ("DISPLAY" !in environment) return r;
    try {
        auto glxinfo = getProcInfo(execute("glxinfo", false), false);
        r.vendor = ("OpenGL vendor string" in glxinfo) ? glxinfo["OpenGL vendor string"] : "Unknown";
        r.model = ("OpenGL renderer string" in glxinfo) ? glxinfo["OpenGL renderer string"] : "Unknown";
        r.coreProfile = ("OpenGL core profile version string" in glxinfo) ? glxinfo["OpenGL core profile version string"] : "Unknown";
        r.vram = ("Video memory" in glxinfo) ? glxinfo["Video memory"] : "Unknown";
    }
    catch (Exception e)
    {
        return r;
    }

    return r;
}

struct OpenSSHInfo
{
    string publicKey;
}

OpenSSHInfo getOpenSSHInfo()
{
    OpenSSHInfo r;

    r.publicKey = execute("cat /etc/ssh/ssh_host_ed25519_key.pub", false);

    return r;
}

struct MachineConfigInfo
{
    string[] kernelModules;
    string[] extraModulePackages;
    string[] availableKernelModules;
    string[] imports;
    string[] literalAttrs;
    string[] blacklistedKernelModules;
    string[] videoDrivers;
}

MachineConfigInfo getMachineConfigInfo()
{
    MachineConfigInfo r;


    // PCI devices
    foreach (path; dirEntries("/sys/bus/pci/devices", SpanMode.shallow).map!(a => a.name).array)
    {
        string vendor = readText(path ~ "/vendor").strip;
        string device = readText(path ~ "/device").strip;
        string _class = readText(path ~ "/class").strip;
        string _module;
        if (exists(path ~ "/driver/module"))
        {
            _module = readLink(path ~ "/driver/module").baseName;
        }

        if (_module != "" && (
                // Mass-storage controller.  Definitely important.
                _class.startsWith("0x01") ||
                //Firewire controller.  A disk might be attached.
                _class.startsWith("0x0c00") ||
                //USB controller.  Needed if we want to use the
                // keyboard when things go wrong in the initrd.
                _class.startsWith("0x0c03")))
        {
            r.availableKernelModules ~= _module;
        }

        // broadcom STA driver (wl.ko)
        // list taken from http://www.broadcom.com/docs/linux_sta/README.txt
        if (vendor.startsWith("0x14e4") &&
            [
                "0x4311", "0x4312", "0x4313",
                "0x4315", "0x4327", "0x4328",
                "0x4329", "0x432a", "0x432b",
                "0x432c", "0x432d", "0x4353",
                "0x4357", "0x4358", "0x4359",
                "0x4331", "0x43a0", "0x43b1"
            ].any!(a => device.startsWith(a)))
        {
            r.extraModulePackages ~= Literal(
                "config.boot.kernelPackages.broadcom_sta");
            r.kernelModules ~= "wl";
        }

        // broadcom FullMac driver
        // list taken from
        // https://wireless.wiki.kernel.org/en/users/Drivers/brcm80211#brcmfmac
        if (vendor.startsWith("0x14e4") && [
                "0x43a3", "0x43df", "0x43ec",
                "0x43d3", "0x43d9", "0x43e9",
                "0x43ba", "0x43bb", "0x43bc",
                "0xaa52", "0x43ca", "0x43cb",
                "0x43cc", "0x43c3", "0x43c4",
                "0x43c5"
            ].any!(a => device.startsWith(a)))
        {
            r.imports ~= Literal(
                "(modulesPath + \"/hardware/network/broadcom-43xx.nix\")");
        }

        // In case this is a virtio scsi device, we need to explicitly make this available.
        if (vendor.startsWith("0x1af4") && ["0x1004", "0x1048"].any!(a => device.startsWith(a)))
        {
            r.availableKernelModules ~= "virtio_scsi";
        }

        // Can't rely on $module here, since the module may not be loaded
        // due to missing firmware.  Ideally we would check modules.pcimap
        // here.
        if (vendor.startsWith("0x8086"))
        {
            if (["0x1043", "0x104f", "0x4220", "0x4221", "0x4223", "0x4224"].any!(
                    a => device.startsWith(a)))
            {
                r.literalAttrs ~= Literal(
                    "networking.enableIntel2200BGFirmware = true;");
            }
            else if (["0x4229", "0x4230", "0x4222", "0x4227"].any!(a => device.startsWith(a)))
            {
                r.literalAttrs ~= Literal(
                    "networking.enableIntel3945ABGFirmware = true;");
            }
        }

        // Assume that all NVIDIA cards are supported by the NVIDIA driver.
        // There may be exceptions (e.g. old cards).
        // FIXME: do we want to enable an unfree driver here?
        if (vendor.startsWith("0x10de") && _class.startsWith("0x03"))
        {
            r.videoDrivers ~= "nvidia";
            r.blacklistedKernelModules ~= "nouveau";
        }
    }

    // USB devices
    foreach (path; dirEntries("/sys/bus/usb/devices", SpanMode.shallow).map!(a => a.name).array)
    {
        if (!exists(path ~ "/bInterfaceClass"))
        {
            continue;
        }
        string _class = readText(path ~ "/bInterfaceClass").strip;
        string subClass = readText(path ~ "/bInterfaceSubClass").strip;
        string protocol = readText(path ~ "/bInterfaceProtocol").strip;

        string _module;
        if (exists(path ~ "/driver/module"))
        {
            _module = readLink(path ~ "/driver/module").baseName;
        }

        if (_module != "" &&
        // Mass-storage controller. Definitely important.
        _class.startsWith("0x08") ||
        // Keyboard. Needed if we want to use the keyboard when things go wrong in the initrd.
        (subClass.startsWith("0x03") || protocol.startsWith("0x01")))
        {
            r.availableKernelModules ~= _module;
        }
    }

    // Block and MMC devices
    foreach (path; (
        (exists("/sys/class/block") ? dirEntries("/sys/class/block", SpanMode.shallow).array : []) ~
        (exists("/sys/class/mmc_host") ? dirEntries("/sys/class/mmc_host", SpanMode.shallow).array : []))
        .map!(a => a.name).array)
    {
        if (exists(path ~ "/device/driver/module")) {
            string _module = readLink(path ~ "/device/driver/module").baseName;
            r.availableKernelModules ~= _module;
        }
    }
    // Bcache
    auto bcacheDevices = dirEntries("/dev", SpanMode.shallow).map!(a => a.name).array.filter!(a => a.startsWith("bcache")).array;
    bcacheDevices = bcacheDevices.filter!(device => device.indexOf("dev/bcachefs") == -1).array;

    if (bcacheDevices.length > 0) {
        r.availableKernelModules ~= "bcache";
    }
    //Prevent unbootable systems if LVM snapshots are present at boot time.
    if (execute("lsblk -o TYPE", false).indexOf("lvm") != -1)
    {
        r.kernelModules ~= "dm-snapshot";
    }
    // Check if we're in a VirtualBox guest. If so, enable the guest additions.
    auto virt = execute!ProcessPipes("systemd-detect-virt", false).stdout.readln.strip;
    switch (virt) {
        case "oracle":
            r.literalAttrs ~= Literal("virtualisation.virtualbox.guest.enable = true;");
            break;
        case "parallels":
            r.literalAttrs ~= Literal("hardware.parallels.enable = true;");
            r.literalAttrs ~= Literal("nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ \"prl-tools\" ];");
            break;
        case "qemu":
        case "kvm":
        case "bochs":
            r.imports ~= Literal("(modulesPath + \"/profiles/qemu-guest.nix\")");
            break;
        case "microsoft":
            r.literalAttrs ~= Literal("virtualization.hypervGuest.enable = true;");
            break;
        case "systemd-nspawn":
            r.literalAttrs ~= Literal("boot.isContainer;");
            break;
        default:
            break;
    }

    return r;
}
