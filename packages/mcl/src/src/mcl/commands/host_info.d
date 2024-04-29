module mcl.commands.host_info;

import cpuid.x86_any;
import cpuid.unified;
import core.cpuid;
import std.system;

import std.stdio : writeln;
import std.conv : to;
import std.string : strip, indexOf;
import std.array : split, join, array;
import std.algorithm : map, filter, startsWith;
import std.file : exists, write, readText;
import std.json;

import mcl.utils.env : parseEnv;
import mcl.utils.json : toJSON;
import mcl.utils.process : execute, isRoot;
import mcl.utils.number : humanReadableSize;
import mcl.utils.array : uniqIfSame;

enum InfoFormat
{
    JSON,
    CSV,
    TSV
}

struct Params
{
    InfoFormat format;
    void setup()
    {
    }
}

string[string] cpuinfo;

string[string] meminfo;

string[string] getProcInfo(string fileOrData, bool awk = true)
{
    string[string] r;
    foreach (line; awk ? execute(["awk", "!$0{exit}1", fileOrData], false).split("\n") : fileOrData.split("\n")) {
        if (line.indexOf(":") == -1 || line.strip == "edid-decode (hex):") {
            continue;
        }
        auto parts = line.split(":");
        if (parts.length >= 2 && parts[0].strip != "") {
            r[parts[0].strip] = parts[1].strip;
        }
    }
    return r;
}

export void host_info()
{
    const params = parseEnv!Params;

    cpuinfo = getProcInfo("/proc/cpuinfo");
    meminfo = getProcInfo("/proc/meminfo");

    Info info;
    info.softwareInfo.operatingSystemInfo = getOperatingSystemInfo();

    info.hardwareInfo.processorInfo = getProcessorInfo();
    info.hardwareInfo.motherBoardInfo = getMotherBoardInfo();
    info.hardwareInfo.memoryInfo = getMemoryInfo();
    info.hardwareInfo.storageInfo = getStorageInfo();
    info.hardwareInfo.displayInfo = getDisplayInfo();
    info.hardwareInfo.graphicsProcessorInfo = getGraphicsProcessorInfo();

    writeln(info.toJSON(true).toPrettyString(JSONOptions.doNotEscapeSlashes));

}

struct Info
{
    SoftwareInfo softwareInfo;
    HardwareInfo hardwareInfo;
}

struct SoftwareInfo
{
    OperatingSystemInfo operatingSystemInfo;
}

struct HardwareInfo
{
    ProcessorInfo processorInfo;
    MotherBoardInfo motherBoardInfo;
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

ArchitectureInfo getArchitectureInfo() {
    ArchitectureInfo r;
    r.architecture = instructionSetArchitecture.to!string;
    r.byteOrder = endian.to!string;
    r.addressSizes = cpuinfo["address sizes"];
    r.opMode = getOpMode();
    r.flags = cpuinfo["flags"].split(" ").map!(a => a.strip).join(", ");

    return r;
}

string getOpMode() {
    int[] opMode = [];
    switch (instructionSetArchitecture) {
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
            throw new Exception("Unsupported architecture" ~ instructionSetArchitecture.to!string);
    }
    return opMode.map!(to!string).join("-bit, ") ~ "-bit";
}

struct ProcessorInfo
{
    ArchitectureInfo architectureInfo;
    char[48] model;
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
    cpuid.x86_any.brand(r.model);
    r.cpus = cpuid.unified.cpus();
    r.cores = [r.cpus * cpuid.unified.cores()];
    r.threads = [cpuid.unified.threads()];
    r.architectureInfo = getArchitectureInfo();

    if (isRoot) {
        auto dmi = execute("dmidecode -t 4", false).split("\n");
        r.voltage = dmi.getFromDmi("Voltage:").map!(a => a.split(" ")[0]).array.uniqIfSame[0];
        r.frequency = dmi.getFromDmi("Current Speed:").map!(a => a.split(" ")[0].to!size_t).array.uniqIfSame;
        r.maxFrequency = dmi.getFromDmi("Max Speed:").map!(a => a.split(" ")[0].to!size_t).array.uniqIfSame;
        r.cpus = dmi.getFromDmi("Processor Information").length;
        r.cores = dmi.getFromDmi("Core Count").map!(a => a.to!size_t).array.uniqIfSame;
        r.threads = dmi.getFromDmi("Thread Count").map!(a => a.to!size_t).array.uniqIfSame;
    }


    return r;
}

struct MotherBoardInfo
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

MotherBoardInfo getMotherBoardInfo()
{
    MotherBoardInfo r;

    r.vendor = execute("cat /sys/devices/virtual/dmi/id/board_vendor", false);
    r.model = execute("cat /sys/devices/virtual/dmi/id/board_name", false);
    r.version_ = execute("cat /sys/devices/virtual/dmi/id/board_version", false);
    if (isRoot) {
        r.serial = execute("cat /sys/devices/virtual/dmi/id/board_serial", false);
    }

    r.biosInfo = getBiosInfo();

    return r;
}

BiosInfo getBiosInfo() {
    BiosInfo r;
    r.date = execute("cat /sys/devices/virtual/dmi/id/bios_date", false);
    r.version_ = execute("cat /sys/devices/virtual/dmi/id/bios_version", false);
    r.release = execute("cat /sys/devices/virtual/dmi/id/bios_release", false);
    r.vendor = execute("cat /sys/devices/virtual/dmi/id/bios_vendor", false);

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

string getKernel() {
    return execute("uname -s", false);
};

string getKernelVersion() {
    return execute("uname -r", false);
}

string getDistribution() {
    auto distribution = execute("uname -o", false);
    if (exists("/etc/os-release")) {
        foreach (line; execute(["awk", "-F", "=", "/^NAME=/ {print $2}", "/etc/os-release"], false).split("\n")) {
            distribution = line;
        }
    }
    else if (distribution == "Darwin") {
        distribution = execute("sw_vers", false);
    }
    else if (exists("/etc/lsb-release")) {
        distribution = execute("lsb_release -i", false);
    }
    return distribution;
}

string getDistributionVersion() {
    auto distributionVersion = execute("uname -r", false);
    if (exists("/etc/os-release")) {
        foreach (line; execute(["awk", "-F", "=", "/^VERSION=/ {print $2}", "/etc/os-release"], false).split("\n")) {
            distributionVersion = line.strip("\"");
        }
    }
    else if (execute("uname -o") == "Darwin") {
        distributionVersion = execute("sw_vers -productVersion", false) ~ " ( " ~ execute("sw_vers -buildVersion", false) ~ " )";
    }
    else if (exists("/etc/lsb-release")) {
        distributionVersion = execute("lsb_release -r", false);
    }
    return distributionVersion;
}

struct MemoryInfo {
    string total;
    size_t count;
    size_t slots;
    string type = "ROOT PERMISSIONS REQUIRED";
    bool[] ecc;
    string speed = "ROOT PERMISSIONS REQUIRED";
}

string[] getFromDmi(string[] dmi, string key) {
    return dmi.filter!(a => a.strip.startsWith(key)).map!(x => x.indexOf(":") != -1 ? x.split(":")[1].strip : x).filter!(a => a != "Unknown" && a != "No Module Installed" && a != "Not Provided" && a != "None").array;
}

MemoryInfo getMemoryInfo() {
    MemoryInfo r;
    auto memTotal = (meminfo["MemTotal"].split(" ")[0].to!size_t) * 1024;
    r.total = memTotal.humanReadableSize;
    if (isRoot) {
        string[] dmi = execute("dmidecode -t memory", false).split("\n");
        r.type = dmi.getFromDmi("Type:").uniqIfSame.join("/");
        r.count = dmi.getFromDmi("Type:").length;
        r.slots = dmi.getFromDmi("Handle").filter!(a => a.indexOf("DMI type 17") != -1).array.length;
        r.total ~= " (" ~ dmi.getFromDmi("Size:").map!(a => a.split(" ")[0]).join("/") ~ ")";
        auto totalWidth = dmi.getFromDmi("Total Width");
        auto dataWidth = dmi.getFromDmi("Data Width");
        foreach (i, width; totalWidth) {
            r.ecc ~= dataWidth[i] != width;
        }
        r.speed = dmi.getFromDmi("Speed:").uniqIfSame.join("/");
    }

    return r;

}

struct Partition {
    string dev;
    string size;
    string type;
    string mount;
    string fslabel;
    string partlabel;
    string id;
}

struct Device {
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

struct StorageInfo {
    string total;
    Device[] devices;
}

StorageInfo getStorageInfo() {
    StorageInfo r;
    auto lsblk = execute!JSONValue("lsblk --nodeps -o KNAME,ID,TYPE,SIZE,MODEL,SERIAL,VENDOR,STATE,PTTYPE,PTUUID -J", false);
    real total = 0;
    foreach (JSONValue dev; lsblk["blockdevices"].array)
    {
        if (dev["id"].isNull) {
            continue;
        }
        Device d;
        d.dev = dev["kname"].str;
        d.uuid = dev["id"].str;
        d.type = dev["type"].isNull ? "" : dev["type"].str;
        d.size = dev["size"].isNull ? "" : dev["size"].str;
        d.model = dev["model"].isNull ? "Uknown Model" : dev["model"].str;
        d.serial = dev["serial"].isNull ? "Missing Serial Number" : dev["serial"].str;
        d.vendor = dev["vendor"].isNull ? "Unknown Vendor" : dev["vendor"].str;
        d.state = dev["state"].str;
        d.partitionTableType = dev["pttype"].str;
        d.partitionTableUUID = dev["ptuuid"].str;


        switch (d.size[$-1]) {
            case 'B':
                total += d.size[0 .. $-1].to!real;
                break;
            case 'K':
                total += d.size[0 .. $-1].to!real * 1024;
                break;
            case 'M':
                total += d.size[0 .. $-1].to!real * 1024 * 1024;
                break;
            case 'G':
                total += d.size[0 .. $-1].to!real * 1024 * 1024 * 1024;
                break;
            case 'T':
                total += d.size[0 .. $-1].to!real * 1024 * 1024 * 1024 * 1024;
                break;
            default:
                assert(0, "Unknown size unit" ~ d.size[$-1]);
        }

        if (isRoot) {
            auto partData = execute!JSONValue("lsblk -o KNAME,SIZE,PARTFLAGS,PARTLABEL,PARTN,PARTTYPE,PARTTYPENAME,PARTUUID,MOUNTPOINT,FSTYPE,LABEL -J /dev/" ~ d.dev, false)["blockdevices"].array;
            foreach (JSONValue part; partData.array)
            {
                if (part["partuuid"].isNull) {
                    continue;
                }
                Partition p;
                p.dev = part["kname"].isNull ? "" : part["kname"].str;
                p.fslabel = part["label"].isNull ? "" :  part["label"].str;
                p.partlabel = part["partlabel"].isNull ? "" : part["partlabel"].str;
                p.size = part["size"].isNull ? "" : part["size"].str;
                p.type = part["fstype"].isNull ? "" : part["fstype"].str;
                p.mount = part["mountpoint"].isNull ? "Not Mounted" : part["mountpoint"].str;
                p.id = part["partuuid"].str;
                d.partitions ~= p;
            }
        }

        r.devices ~= d;
    }
    r.total = total.humanReadableSize;

    return r;
}

struct Display {
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

struct DisplayInfo {
    Display[] displays;
    size_t count;
}

DisplayInfo getDisplayInfo() {
    DisplayInfo r;

    auto xrandr = execute!JSONValue("jc xrandr --properties")["screens"].array[0]["devices"].array;
    foreach (JSONValue screen; xrandr) {
        Display d;

        d.name = screen["device_name"].str;
        d.connected = screen["is_connected"].boolean;
        d.primary = screen["is_primary"].boolean;
        d.resolution = screen["resolution_width"].integer.to!string ~ "x" ~ screen["resolution_height"].integer.to!string;
        foreach (JSONValue mode; screen["modes"].array) {
            foreach (JSONValue freq; mode["frequencies"].array) {
                d.modes ~= mode["resolution_width"].integer.to!string ~ "x" ~ mode["resolution_height"].integer.to!string ~ "@" ~ freq["frequency"].floating.to!string ~ "Hz";
                if (freq["is_current"].boolean) {
                    d.refreshRate = freq["frequency"].floating.to!string ~ "Hz";
                }
            }
        }

        auto edidTmp = execute("edid-decode /sys/class/drm/card0-" ~ d.name ~ "/edid", false);
        auto edidData = getProcInfo(edidTmp, false);
        d.vendor = edidData["Manufacturer"];
        d.model = edidData["Model"];
        d.serial = edidData["Serial Number"];
        d.manufactureDate = edidData["Made in"];
        d.size = edidData["Maximum image size"];

        r.displays ~= d;
        r.count++;
    }
    return r;
}

struct GraphicsProcessorInfo {
    string vendor;
    string model;
    string coreProfile;
    string vram;
}

GraphicsProcessorInfo getGraphicsProcessorInfo() {
    GraphicsProcessorInfo r;

    auto glxinfo = getProcInfo(execute("glxinfo", false), false);
    r.vendor = glxinfo["OpenGL vendor string"];
    r.model = glxinfo["OpenGL renderer string"];
    r.coreProfile = glxinfo["OpenGL core profile version string"];
    r.vram = glxinfo["Video memory"];

    return r;
}
