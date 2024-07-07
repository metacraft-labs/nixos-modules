module mcl.utils.ssh;

struct Host
{
    Ipv4 address;
    string hostname;
    string username;
}

struct Ipv4
{
    ubyte[4] octets;
    alias octets this;

    this(string ip)
    {
        import std.algorithm : splitter;
        import std.conv : to;
        auto parts = ip.splitter(".");
        size_t i = 0;
        foreach (part; parts)
        {
            this.octets[i++] = part.to!ubyte;
        }
    }

    this(ubyte[3] networkId, ubyte hostId)
    {
        octets[0 .. 3] = networkId;
        octets[3] = hostId;
    }

    void toString(W)(auto ref W writer) const
    {
        import std.format : formattedWrite;
        writer.formattedWrite(
            "%d.%d.%d.%d",
            octets[0], octets[1], octets[2], octets[3]
        );
    }

    string toString() const
    {
        import std.format : format;
        return format("%s", this);
    }
}

version (unittest)

unittest
{
    Ipv4 addr1 = Ipv4("192.168.2.3");
    assert(addr1[0] == 192);
    assert(addr1[1] == 168);
    assert(addr1[2] == 2);
    assert(addr1[3] == 3);
    assert(addr1.toString == "192.168.2.3");

    Ipv4 addr2 = Ipv4([10, 123, 4], 5);
    assert(addr2[0] == 10);
    assert(addr2[1] == 123);
    assert(addr2[2] == 4);
    assert(addr2[3] == 5);
    assert(addr2.toString == "10.123.4.5");
}

string sshPath(string username, Ipv4 address)
{
    return username ~ "@" ~ address.toString;
}

Host[] scan_hosts(ubyte[3] networkId, ubyte startHostId, ubyte endHostId, string user)
{
    import std;
    import mcl.utils.process2 : execute, executeStatusOnly;

    // -o "UserKnownHostsFile=/dev/null" -o StrictHostKeyChecking=no -o BatchMode=yes
    static immutable sshOpts = ["-o", "UserKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes"];

    // ssh-keyscan -T 1 -4 "$ip"
    static immutable sshKeyscanCmd = ["ssh-keyscan", "-T", "1", "-4"];

    Host[] hosts;
    foreach (int i; iota(startHostId, endHostId + 1).parallel)
    {
        auto host = Host(address: Ipv4(networkId, i.to!ubyte));
        writef("Checking %s -", host.address);

        if (executeStatusOnly(sshKeyscanCmd ~ host.address.toString))
        {
            writef(" ✅ | hostname: ");
            auto hostname = execute!(string, true)(["ssh"] ~ sshOpts ~ sshPath(user, host.address));
            if (hostname.status == 0)
            {
                writeln(hostname.output);
                host.username = user;
                host.hostname = hostname.output.strip;
            }
            else
                writeln("❌");
            hosts ~= host;
        }
        else
            writeln(" ❌");
    }
    return hosts;
}

